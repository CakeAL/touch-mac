//! 视频接收：Sunshine 的“定长切片 + NV_VIDEO_PACKET”协议（不是标准 RTP/H.264）。
//!
//! 线上每包（总长 packetSize + 16）：
//!   12B RTP 头 | 4B 保留 | 16B NV_VIDEO_PACKET | payload
//! 其中 payload 长度 = packetSize - 16；帧的第一个数据分片前还有 8B 帧头，
//! 其后是 Annex-B 字节流（没有 FU-A/STAP-A，切片可能从 NAL 中间切断）。
//! 帧边界只由 NV 头的 SOF/EOF 标志决定，RTP marker 恒为 0。
use bytes::{Bytes, BytesMut};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{broadcast, watch};
use tokio::time::{interval, Duration};

use crate::relay::VideoMsg;

/// RTP(12) + 保留(4) + NV 头(16)
const PAYLOAD_OFF: usize = 32;
const FLAG_PIC: u8 = 0x01;
const FLAG_EOF: u8 = 0x02;
const FLAG_SOF: u8 = 0x04;

/// SDP 里 x-nv-video[0].packetSize
pub const PACKET_SIZE: usize = 1392;
const PAYLOAD_BLOCKSIZE: usize = PACKET_SIZE - 16;

struct Frame {
    index: u32,
    ts: u32,
    frame_type: u8,
    first_block: u32,
    last_block: u32,
    /// block 序号 -> 该分片的 payload（乱序到达先缓存，帧末尾统一按序拼接）
    pieces: BTreeMap<u32, Bytes>,
    started: bool,
}

impl Frame {
    fn new(index: u32, ts: u32, block: u32) -> Self {
        Frame {
            index,
            ts,
            frame_type: 1,
            first_block: block,
            last_block: block,
            pieces: BTreeMap::new(),
            started: false,
        }
    }
}

/// 收流并转发。`server` 是 RTSP SETUP 给的视频端口，`ping_payload` 来自 SETUP 响应头。
pub async fn run(
    server: SocketAddr,
    ping_payload: Option<[u8; 16]>,
    tx: broadcast::Sender<VideoMsg>,
    last_config: watch::Sender<Option<Arc<Bytes>>>,
) -> anyhow::Result<()> {
    let sock = Arc::new(UdpSocket::bind("0.0.0.0:0").await?);
    // IDR 帧可能是 ~150 个 1408B 的突刺，默认收缓冲会丢包。
    unsafe {
        use std::os::fd::AsRawFd;
        let sz: libc::c_int = 8 * 1024 * 1024;
        libc::setsockopt(
            sock.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &sz as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
    sock.connect(server).await?;
    eprintln!("[video] udp local {} -> {server}", sock.local_addr()?);

    // 500ms 一次 ping：既保活，也让服务器学到我们的地址（先 ping 才会推流）。
    {
        let sock = sock.clone();
        tokio::spawn(async move {
            let mut tick = interval(Duration::from_millis(500));
            let mut seq: u32 = 0;
            loop {
                tick.tick().await;
                let mut buf = [0u8; 20];
                let mut len = 4;
                if let Some(p) = &ping_payload {
                    buf[..16].copy_from_slice(p);
                    buf[16..].copy_from_slice(&seq.to_be_bytes());
                    len = 20;
                } else {
                    buf[..4].copy_from_slice(b"PING");
                }
                seq = seq.wrapping_add(1);
                if let Err(e) = sock.send(&buf[..len]).await {
                    eprintln!("[video] ping: {e}");
                }
            }
        });
    }

    let mut cur: Option<Frame> = None;
    let mut buf = vec![0u8; 4096];
    let mut frames: u64 = 0;
    loop {
        let n = match sock.recv(&mut buf).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[video] recv: {e}");
                tokio::time::sleep(Duration::from_millis(20)).await;
                continue;
            }
        };
        if n <= PAYLOAD_OFF {
            continue;
        }
        if buf[0] & 0xC0 != 0x80 {
            continue; // RTP 版本必须是 2
        }
        let ts = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let spi = u32::from_le_bytes([buf[16], buf[17], buf[18], buf[19]]);
        let frame_index = u32::from_le_bytes([buf[20], buf[21], buf[22], buf[23]]);
        let flags = buf[24];
        let fec_info = u32::from_le_bytes([buf[28], buf[29], buf[30], buf[31]]);
        // fecInfo: 低 12 位以上是 fecIdx，高 10 位是 dataShards。
        let fec_idx = (fec_info >> 12) & 0x3FF;
        let data_shards = (fec_info >> 22) & 0x3FF;
        if data_shards > 0 && fec_idx >= data_shards {
            continue; // Reed-Solomon 校验分片：其头字段不是真实索引，必须丢弃
        }
        if flags & FLAG_PIC == 0 {
            continue;
        }
        let block = spi >> 8;
        let payload = &buf[PAYLOAD_OFF..n];

        // 帧切换：直接用 frameIndex 判定。
        let mut f = match cur.take() {
            Some(f) if f.index == frame_index => f,
            _ => Frame::new(frame_index, ts, block),
        };
        if block < f.first_block {
            f.first_block = block;
        }
        if block > f.last_block {
            f.last_block = block;
        }
        if flags & FLAG_SOF != 0 && payload.len() >= 8 {
            f.started = true;
            f.frame_type = payload[3];
            let hdr = if payload[0] == 0x01 {
                8
            } else if payload[0] == 0x81 {
                44
            } else {
                8
            };
            f.pieces.insert(block, Bytes::copy_from_slice(&payload[hdr.min(payload.len())..]));
        } else {
            f.pieces.insert(block, Bytes::copy_from_slice(payload));
        }

        if flags & FLAG_EOF != 0 {
            if f.started {
                match assemble(&mut f) {
                    Some(data) => {
                        frames += 1;
                        emit(f, data, frames, &tx, &last_config);
                    }
                    None => eprintln!(
                        "[video] 丢帧 {}（分片缺口 {}..={} 共 {} 片, started={}）",
                        f.index,
                        f.first_block,
                        f.last_block,
                        f.pieces.len(),
                        f.started
                    ),
                }
            }
        } else {
            cur = Some(f);
        }
    }
}

/// 按 block 序号把分片拼成完整 AU；有缺口则返回 None。
fn assemble(f: &mut Frame) -> Option<BytesMut> {
    let want = (f.last_block - f.first_block) as usize + 1;
    if f.pieces.len() != want {
        return None;
    }
    let mut out = BytesMut::with_capacity(want * PAYLOAD_BLOCKSIZE);
    for b in f.first_block..=f.last_block {
        out.extend_from_slice(f.pieces.get(&b)?);
    }
    Some(out)
}

fn emit(f: Frame, mut data: BytesMut, n: u64, tx: &broadcast::Sender<VideoMsg>, last: &watch::Sender<Option<Arc<Bytes>>>) {
    // 末片本身就是短包，拼接时已按真实长度处理，只需去掉尾部零填充。
    while data.last() == Some(&0) {
        data.truncate(data.len() - 1);
    }
    let (sps, pps, idr) = scan(&data);
    if let (Some(sps), Some(pps)) = (sps, pps) {
        let mut csd = BytesMut::with_capacity(sps.len() + pps.len());
        csd.extend_from_slice(&sps);
        csd.extend_from_slice(&pps);
        let csd = csd.freeze();
        let csd = Arc::new(csd);
        // 每个 IDR 都带 SPS/PPS，但只有在变化时才重下 CONFIG，否则客户端会不停重建解码器。
        let same = last.borrow().as_ref().map(|c| c.as_ref() == csd.as_ref()).unwrap_or(false);
        if !same {
            let _ = last.send(Some(csd.clone()));
            let _ = tx.send(VideoMsg::Config(csd));
        }
    }
    let key = idr || f.frame_type == 2;
    let pts_us = (f.ts as u64 * 1000 + 45) / 90;
    if key || data.len() > 50000 || n % 120 == 1 {
        eprintln!("[video] frame #{n} idx={} {}B key={key} pts={pts_us}us", f.index, data.len());
    }
    let _ = tx.send(VideoMsg::Frame { pts_us, key, data: Arc::new(data.freeze()) });
}

/// 扫 Annex-B 找 SPS(7)/PPS(8) 与 IDR(5)，返回（拷贝后的）参数集。
fn scan(data: &[u8]) -> (Option<Bytes>, Option<Bytes>, bool) {
    let mut sps: Option<Bytes> = None;
    let mut pps: Option<Bytes> = None;
    let mut idr = false;
    let mut i = 0usize;
    while i + 3 < data.len() {
        let sc = if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            3
        } else if i + 4 < data.len() && data[i..i + 4] == [0, 0, 0, 1] {
            4
        } else {
            i += 1;
            continue;
        };
        let hdr = i + sc;
        if hdr >= data.len() {
            break;
        }
        let nal_type = data[hdr] & 0x1F;
        // 下一个起始码作为本 NAL 结束
        let mut j = hdr + 1;
        while j + 3 < data.len() {
            if data[j] == 0 && data[j + 1] == 0 && (data[j + 2] == 1 || (data[j + 2] == 0 && j + 3 < data.len() && data[j + 3] == 1)) {
                break;
            }
            j += 1;
        }
        let end = j.min(data.len());
        let nal = Bytes::copy_from_slice(&data[i..end]);
        match nal_type {
            7 if sps.is_none() => sps = Some(nal),
            8 if pps.is_none() => pps = Some(nal),
            5 => idr = true,
            _ => {}
        }
        i = end.max(i + sc + 1);
    }
    (sps, pps, idr)
}

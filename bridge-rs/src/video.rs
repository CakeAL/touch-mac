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
    on_loss: Arc<dyn Fn() + Send + Sync>,
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
    // 放在主循环里 select，会话结束时随任务一起退出，不留后台线程。
    let mut tick = interval(Duration::from_millis(500));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut ping_seq: u32 = 0;
    let mut pingbuf = [0u8; 20];
    if let Some(p) = &ping_payload {
        pingbuf[..16].copy_from_slice(p);
    }

    let mut cur: Option<Frame> = None;
    let mut buf = vec![0u8; 4096];
    let mut frames: u64 = 0;
    loop {
        let n = tokio::select! {
            _ = tick.tick() => {
                let (bufp, len) = match &ping_payload {
                    Some(_) => {
                        pingbuf[16..].copy_from_slice(&ping_seq.to_be_bytes());
                        ping_seq = ping_seq.wrapping_add(1);
                        (&pingbuf[..], 20)
                    }
                    None => (&b"PING"[..], 4),
                };
                if let Err(e) = sock.send(&bufp[..len]).await {
                    eprintln!("[video] ping: {e}");
                }
                continue;
            }
            r = sock.recv(&mut buf) => match r {
                Ok(n) => n,
                Err(e) => {
                    eprintln!("[video] recv: {e}");
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    continue;
                }
            },
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
                    None => {
                        on_loss();
                        eprintln!(
                        "[video] 丢帧 {}（分片缺口 {}..={} 共 {} 片, started={}）",
                        f.index,
                        f.first_block,
                        f.last_block,
                        f.pieces.len(),
                        f.started
                        );
                    }
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
    let sc = scan(&data);
    if let Some(csd) = sc.csd {
        // CONFIG = u8 codec(0=H.264, 1=HEVC) + Annex-B 参数集，只在变化时下发。
        let mut buf = BytesMut::with_capacity(csd.len() + 1);
        buf.extend_from_slice(&[if sc.hevc { 1 } else { 0 }]);
        buf.extend_from_slice(&csd);
        let csd = Arc::new(buf.freeze());
        let same = last.borrow().as_ref().map(|c| c.as_ref() == csd.as_ref()).unwrap_or(false);
        if !same {
            eprintln!("[video] CONFIG {} {}B", if sc.hevc { "HEVC" } else { "H.264" }, csd.len() - 1);
            let _ = last.send(Some(csd.clone()));
            let _ = tx.send(VideoMsg::Config(csd));
        }
    }
    let key = sc.key || f.frame_type == 2;
    let pts_us = (f.ts as u64 * 1000 + 45) / 90;
    if key || data.len() > 50000 || n % 120 == 1 {
        eprintln!("[video] frame #{n} idx={} {}B key={key} pts={pts_us}us", f.index, data.len());
    }
    // 每秒打一次实际入帧帧率，便于确认 60/120 Hz 是否真的生效。
    {
        static CNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        static T0: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let c = CNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let now = crate::now_us();
        let mut t0 = T0.load(std::sync::atomic::Ordering::Relaxed);
        if t0 == 0 {
            T0.store(now, std::sync::atomic::Ordering::Relaxed);
            t0 = now;
        }
        if now > t0 + 2_000_000 {
            let fps = (c as f64) * 1_000_000.0 / ((now - t0) as f64);
            // 采集→到达：pts 是刻进码流的捕获时间（90kHz），与单调时钟的差值即为
            // Sunshine 抓屏 + 编码 + UDP 回环的总耗时（用首帧做基线消掉未知起点）。
            static BASE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let diff = now.saturating_sub(pts_us);
            let mut base = BASE.load(std::sync::atomic::Ordering::Relaxed);
            if base == 0 {
                BASE.store(diff, std::sync::atomic::Ordering::Relaxed);
                base = diff;
            }
            let enc_ms = diff.saturating_sub(base) as f64 / 1000.0;
            eprintln!(
                "[video] 入帧帧率 {fps:.1} fps（{c} 帧 / {:.2}s）  采集→到达 ~{enc_ms:.1} ms",
                (now - t0) as f64 / 1e6
            );
            CNT.store(0, std::sync::atomic::Ordering::Relaxed);
            T0.store(now, std::sync::atomic::Ordering::Relaxed);
        }
    }
    let send_us = crate::now_us();
    let _ = tx.send(VideoMsg::Frame { pts_us, key, send_us, data: Arc::new(data.freeze()) });
}

/// Annex-B 扫描结果：参数集（按码流判定 H.264 / HEVC）与是否关键帧。
struct Scan {
    hevc: bool,
    csd: Option<Bytes>,
    key: bool,
}

/// 扫 Annex-B：H.264 取 SPS(7)/PPS(8)、IDR(5)；HEVC 取 VPS(32)/SPS(33)/PPS(34)、IRAP(16..=23)。
fn scan(data: &[u8]) -> Scan {
    let mut h264_sps: Option<Bytes> = None;
    let mut h264_pps: Option<Bytes> = None;
    let mut h264_idr = false;
    let mut vps: Option<Bytes> = None;
    let mut hevc_sps: Option<Bytes> = None;
    let mut hevc_pps: Option<Bytes> = None;
    let mut hevc_irap = false;

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
        let b = data[hdr];
        let h264_type = b & 0x1F;
        let hevc_type = (b >> 1) & 0x3F;

        // 下一个起始码作为本 NAL 结束
        let mut j = hdr + 1;
        while j + 3 < data.len() {
            if data[j] == 0
                && data[j + 1] == 0
                && (data[j + 2] == 1
                    || (data[j + 2] == 0 && j + 3 < data.len() && data[j + 3] == 1))
            {
                break;
            }
            j += 1;
        }
        let end = j.min(data.len());
        let nal = Bytes::copy_from_slice(&data[i..end]);

        match h264_type {
            7 if h264_sps.is_none() => h264_sps = Some(nal.clone()),
            8 if h264_pps.is_none() => h264_pps = Some(nal.clone()),
            5 => h264_idr = true,
            _ => {}
        }
        match hevc_type {
            32 if vps.is_none() => vps = Some(nal.clone()),
            33 if hevc_sps.is_none() => hevc_sps = Some(nal),
            34 if hevc_pps.is_none() => hevc_pps = Some(nal),
            16..=23 => hevc_irap = true,
            _ => {}
        }
        i = end.max(i + sc + 1);
    }

    // HEVC 检出 VPS/SPS 即认定 HEVC（H.264 的 7/8 在 HEVC 解释下是 3/4，不会误判成参数集）。
    let hevc = vps.is_some() || (hevc_sps.is_some() && hevc_pps.is_some());
    if hevc {
        let mut csd = BytesMut::new();
        for p in [vps, hevc_sps, hevc_pps].into_iter().flatten() {
            csd.extend_from_slice(&p);
        }
        Scan { hevc: true, csd: if csd.is_empty() { None } else { Some(csd.freeze()) }, key: hevc_irap }
    } else {
        let mut csd = BytesMut::new();
        for p in [h264_sps, h264_pps].into_iter().flatten() {
            csd.extend_from_slice(&p);
        }
        Scan { hevc: false, csd: if csd.is_empty() { None } else { Some(csd.freeze()) }, key: h264_idr }
    }
}

//! 音频接收：Sunshine 以 RTP 封装的 Opus 发到客户端音频端口。
//!
//! 只取 payloadType=97 的数据包（FEC 包 127 直接丢弃），把 Opus 原始帧连同
//! 90kHz 时间戳一起交给 relay。控制流/音频加密保持关闭（我们只开 SS_ENC_CONTROL_V2），
//! 因此这里拿到的就是明文 Opus。
use bytes::Bytes;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::broadcast;

#[derive(Debug)]
pub struct AudioPacket {
    pub pts_us: u64,
    /// 交错立体声 16-bit PCM，48 kHz。
    pub pcm: Bytes,
}

const SAMPLE_RATE: i32 = 48000;
const CHANNELS: i32 = 2;

#[repr(C)]
struct OpusDecoderRaw {
    _private: [u8; 0],
}

/// opus 解码器句柄：裸指针本身不是 Send，但解码器只被音频任务独占使用。
struct Decoder(*mut OpusDecoderRaw);
unsafe impl Send for Decoder {}

extern "C" {
    fn opus_decoder_create(fs: i32, channels: i32, error: *mut i32) -> *mut OpusDecoderRaw;
    fn opus_decode(
        st: *mut OpusDecoderRaw,
        data: *const u8,
        len: i32,
        pcm: *mut i16,
        frame_size: i32,
        decode_fec: i32,
    ) -> i32;
    fn opus_decoder_destroy(st: *mut OpusDecoderRaw);
}

/// 绑定本地端口并向服务端音频端口发保活 ping；服务端随后把 Opus 发到这里。
pub async fn run(
    server: SocketAddr,
    ping: Option<[u8; 16]>,
    tx: broadcast::Sender<Arc<AudioPacket>>,
) -> anyhow::Result<()> {
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    let local = sock.local_addr()?;
    sock.connect(server).await?;
    eprintln!("[audio] udp local {local} -> {server}");

    let mut err: i32 = 0;
    let raw = unsafe { opus_decoder_create(SAMPLE_RATE, CHANNELS, &mut err) };
    if raw.is_null() || err != 0 {
        return Err(anyhow::anyhow!("opus_decoder_create 失败: {err}"));
    }
    let dec = Decoder(raw);
    let mut pcm = vec![0i16; 5760 * CHANNELS as usize];

    let mut buf = vec![0u8; 4096];
    let mut pingbuf = [0u8; 20];
    if let Some(p) = ping {
        pingbuf[..16].copy_from_slice(&p);
    }
    let mut seq: u32 = 0;
    let mut n: u64 = 0;
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = tick.tick() => {
                match ping {
                    None => { sock.send(b"PING").await?; }
                    Some(_) => {
                        pingbuf[16..20].copy_from_slice(&seq.to_be_bytes());
                        seq = seq.wrapping_add(1);
                        sock.send(&pingbuf).await?;
                    }
                }
            }
            r = sock.recv(&mut buf) => {
                let got = r?;
                if got <= 12 { continue; }
                let payload_type = buf[1] & 0x7f;
                if payload_type != 97 {
                    continue; // 127 = FEC 纠错包，这层不做恢复
                }
                let ts = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
                let opus = &buf[12..got];
                let frames = unsafe {
                    opus_decode(
                        dec.0,
                        opus.as_ptr(),
                        opus.len() as i32,
                        pcm.as_mut_ptr(),
                        (pcm.len() / CHANNELS as usize) as i32,
                        0,
                    )
                };
                if frames <= 0 {
                    continue;
                }
                let samples = frames as usize * CHANNELS as usize;
                let peak = pcm[..samples].iter().map(|s| s.unsigned_abs()).max().unwrap_or(0);
                let mut bytes = vec![0u8; samples * 2];
                for (i, s) in pcm[..samples].iter().enumerate() {
                    let b = s.to_le_bytes();
                    bytes[i * 2] = b[0];
                    bytes[i * 2 + 1] = b[1];
                }
                let pkt = Arc::new(AudioPacket {
                    pts_us: ts as u64 * 1000 / 90,
                    pcm: Bytes::from(bytes),
                });
                n += 1;
                if n % 250 == 1 {
                    eprintln!("[audio] {n} 包，pcm {}B pts={}us peak={}", pkt.pcm.len(), pkt.pts_us, peak);
                }
                let _ = tx.send(pkt);
            }
        }
    }
}

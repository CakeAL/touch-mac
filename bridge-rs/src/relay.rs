//! 视频中转：把 access unit 按固定帧头写给 adb reverse 过来的平板。
use bytes::Bytes;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, watch};
use crate::audio::AudioPacket;

pub const MSG_CONFIG: u8 = 0x01;
pub const MSG_FRAME: u8 = 0x02;
pub const MSG_AUDIO: u8 = 0x03;
pub const MSG_TICK: u8 = 0x04;

#[derive(Clone, Debug)]
pub enum VideoMsg {
    Config(Arc<Bytes>),
    Frame { pts_us: u64, key: bool, send_us: u64, data: Arc<Bytes> },
}

pub async fn serve(
    addr: SocketAddr,
    rx: broadcast::Receiver<VideoMsg>,
    last_config: watch::Receiver<Option<Arc<Bytes>>>,
    audio_rx: broadcast::Receiver<Arc<AudioPacket>>,
    audio_enabled: bool,
    on_client: Arc<dyn Fn() + Send + Sync>,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind(addr).await?;
    eprintln!("[video] relay listening on {}", addr);
    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[video] accept: {e}");
                continue;
            }
        };
        eprintln!("[video] client {peer}");
        on_client(); // 新观众必须等一个 IDR 才能起播
        let rx = rx.resubscribe();
        let arx = audio_rx.resubscribe();
        let cfg = last_config.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(sock, rx, arx, cfg, audio_enabled).await {
                eprintln!("[video] {peer}: {e}");
            }
            eprintln!("[video] {peer} closed");
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    mut rx: broadcast::Receiver<VideoMsg>,
    mut arx: broadcast::Receiver<Arc<AudioPacket>>,
    last_config: watch::Receiver<Option<Arc<Bytes>>>,
    audio_enabled: bool,
) -> anyhow::Result<()> {
    sock.set_nodelay(true).ok();
    let initial = last_config.borrow().clone();
    if let Some(cfg) = initial {
        write_msg(&mut sock, MSG_CONFIG, &cfg).await?;
    }
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(100));
    loop {
        tokio::select! {
            _ = tick.tick() => {
                // 纯延时探针：100ms 一条，平板端用到达时间 - 该时刻 量单程延时
                let mut head = [0u8; 8];
                head.copy_from_slice(&crate::now_us().to_be_bytes());
                write_msg2(&mut sock, MSG_TICK, &head, &[]).await?;
            }
            m = rx.recv() => match m {
                Ok(VideoMsg::Config(c)) => write_msg(&mut sock, MSG_CONFIG, &c).await?,
                Ok(VideoMsg::Frame { pts_us, key, send_us, data }) => {
                    let mut head = [0u8; 17];
                    head[..8].copy_from_slice(&pts_us.to_be_bytes());
                    head[8] = key as u8;
                    head[9..17].copy_from_slice(&send_us.to_be_bytes());
                    write_msg2(&mut sock, MSG_FRAME, &head, &data).await?;
                    // 桥内排队 + TCP 写入耗时（不含 adb/USB 与平板侧），用于给延时拆段。
                    static SUM: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                    let d = crate::now_us().saturating_sub(send_us);
                    let s1 = SUM.fetch_add(d, std::sync::atomic::Ordering::Relaxed) + d;
                    let n1 = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                    if n1 % 120 == 0 {
                        eprintln!("[video] 桥内排队+写入 {:.1} ms（n={n1}）", s1 as f64 / n1 as f64 / 1000.0);
                        SUM.store(0, std::sync::atomic::Ordering::Relaxed);
                        N.store(0, std::sync::atomic::Ordering::Relaxed);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    eprintln!("[video] client lagged {n} frames");
                }
                Err(broadcast::error::RecvError::Closed) => return Ok(()),
            },
            a = arx.recv() => match a {
                Ok(pkt) if audio_enabled => {
                    // 头 8 字节放发送时刻（平板用它量小包传输延时；音频不需要 pts）
                    let mut head = [0u8; 8];
                    head.copy_from_slice(&crate::now_us().to_be_bytes());
                    write_msg2(&mut sock, MSG_AUDIO, &head, &pkt.pcm).await?;
                }
                Ok(_) => {}
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return Ok(()),
            },
        }
    }
}

async fn write_msg(sock: &mut TcpStream, ty: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut head = [0u8; 5];
    head[0] = ty;
    head[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    sock.write_all(&head).await?;
    sock.write_all(payload).await
}

async fn write_msg2(
    sock: &mut TcpStream,
    ty: u8,
    extra: &[u8],
    payload: &[u8],
) -> std::io::Result<()> {
    let mut head = [0u8; 5];
    head[0] = ty;
    head[1..5].copy_from_slice(&((extra.len() + payload.len()) as u32).to_be_bytes());
    sock.write_all(&head).await?;
    sock.write_all(extra).await?;
    sock.write_all(payload).await
}

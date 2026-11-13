//! 视频中转：把 access unit 按固定帧头写给 adb reverse 过来的平板。
use bytes::Bytes;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, watch};

pub const MSG_CONFIG: u8 = 0x01;
pub const MSG_FRAME: u8 = 0x02;

#[derive(Clone, Debug)]
pub enum VideoMsg {
    Config(Arc<Bytes>),
    Frame { pts_us: u64, key: bool, data: Arc<Bytes> },
}

pub async fn serve(
    addr: SocketAddr,
    rx: broadcast::Receiver<VideoMsg>,
    last_config: watch::Receiver<Option<Arc<Bytes>>>,
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
        let cfg = last_config.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(sock, rx, cfg).await {
                eprintln!("[video] {peer}: {e}");
            }
            eprintln!("[video] {peer} closed");
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    mut rx: broadcast::Receiver<VideoMsg>,
    last_config: watch::Receiver<Option<Arc<Bytes>>>,
) -> anyhow::Result<()> {
    sock.set_nodelay(true).ok();
    let initial = last_config.borrow().clone();
    if let Some(cfg) = initial {
        write_msg(&mut sock, MSG_CONFIG, &cfg).await?;
    }
    loop {
        match rx.recv().await {
            Ok(VideoMsg::Config(c)) => write_msg(&mut sock, MSG_CONFIG, &c).await?,
            Ok(VideoMsg::Frame { pts_us, key, data }) => {
                let mut head = [0u8; 9];
                head[..8].copy_from_slice(&pts_us.to_be_bytes());
                head[8] = key as u8;
                write_msg2(&mut sock, MSG_FRAME, &head, &data).await?;
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                eprintln!("[video] client lagged {n} frames");
            }
            Err(broadcast::error::RecvError::Closed) => return Ok(()),
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

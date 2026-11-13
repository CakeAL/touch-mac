//! 平板触控接入：TCP 文本行 → 归一化触控事件。
use anyhow::Result;
use std::net::SocketAddr;
use tokio::io::{AsyncBufReadExt, BufReader, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

#[derive(Clone, Copy, Debug)]
pub enum TouchKind {
    Down,
    Move,
    Up,
    Cancel,
}

#[derive(Clone, Copy, Debug)]
pub struct TouchEvent {
    pub kind: TouchKind,
    pub id: u32,
    pub x: f32,
    pub y: f32,
}

fn clamp01(v: f32) -> f32 {
    if v < 0.0 { 0.0 } else if v > 1.0 { 1.0 } else { v }
}

fn parse(line: &str) -> Option<Option<TouchEvent>> {
    let mut it = line.split_whitespace();
    let k = it.next()?;
    if k == "c" {
        return Some(None);
    }
    let kind = match k {
        "d" => TouchKind::Down,
        "m" => TouchKind::Move,
        "u" => TouchKind::Up,
        _ => return None,
    };
    let id: u32 = it.next()?.parse().ok()?;
    if id > 31 {
        return None;
    }
    let x: f32 = it.next()?.parse().ok()?;
    let y: f32 = it.next()?.parse().ok()?;
    Some(Some(TouchEvent { kind, id, x: clamp01(x), y: clamp01(y) }))
}

/// 监听触控连接；每个连接把事件灌进 mpsc。`aspect` 是该连接的显示器宽高比握手值。
pub async fn serve(
    addr: SocketAddr,
    tx: mpsc::Sender<TouchEvent>,
    aspect: f32,
    screen: tokio::sync::watch::Sender<(u32, u32, u32)>,
    clients: tokio::sync::watch::Sender<usize>,
    idr: tokio::sync::watch::Sender<u64>,
) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    eprintln!("[touch] listening on {}", addr);
    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[touch] accept: {e}");
                continue;
            }
        };
        eprintln!("[touch] client {peer}");
        let tx = tx.clone();
        let cl = clients.clone();
        let idr = idr.clone();
        let scr = screen.clone();
        cl.send_modify(|n| *n += 1);
        tokio::spawn(async move {
            if let Err(e) = handle(sock, tx, aspect, scr, idr).await {
                eprintln!("[touch] {peer}: {e}");
            }
            cl.send_modify(|n| *n = n.saturating_sub(1));
            eprintln!("[touch] client {peer} 断开");
        });
    }
}

async fn handle(
    sock: TcpStream,
    tx: mpsc::Sender<TouchEvent>,
    aspect: f32,
    screen: tokio::sync::watch::Sender<(u32, u32, u32)>,
    idr: tokio::sync::watch::Sender<u64>,
) -> Result<()> {
    let (rd, mut wr) = sock.into_split();
    // 握手：先发目标宽高比，平板据此画活动框。
    let _ = wr
        .write_all(format!("#aspect {aspect:.6}\n").as_bytes())
        .await;
    let _ = wr
        .write_all(format!("#t0 {}\n", crate::now_us()).as_bytes())
        .await;
    let mut lines = BufReader::new(rd).lines();
    let mut sent_cancel = false;
    while let Some(line) = lines.next_line().await? {
        match parse(&line) {
            Some(Some(ev)) => {
                sent_cancel = false;
                let _ = tx.send(ev).await;
            }
            Some(None) => {
                sent_cancel = true;
                let _ = tx
                    .send(TouchEvent { kind: TouchKind::Cancel, id: 0, x: 0.0, y: 0.0 })
                    .await;
            }
            None => {
                let t = line.trim();
                if t == "h" {
                    // 单向心跳：平板用 收到时间 - 该时刻 判断单程延时（不需要往返）
                    let _ = wr
                        .write_all(format!("#hb {}\n", crate::now_us()).as_bytes())
                        .await;
                } else if t == "i" {
                    // 平板解码端丢了参考帧（队列溢出/清空），请桥立刻要一个 IDR。
                    idr.send_modify(|n| *n += 1);
                } else if let Some(rest) = t.strip_prefix("s ") {
                    // 平板上报自己的屏幕尺寸（像素）：桥据此按比例决定编码尺寸。
                    let mut it = rest.split_whitespace();
                    let w: Option<u32> = it.next().and_then(|v| v.parse().ok());
                    let h: Option<u32> = it.next().and_then(|v| v.parse().ok());
                    let r: u32 = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                    if let (Some(w), Some(h)) = (w, h) {
                        if w > 0 && h > 0 && *screen.borrow() != (w, h, r) {
                            let _ = screen.send((w, h, r));
                            eprintln!("[touch] 平板屏幕 {w}x{h} 偏好 {r}p");
                        }
                    }
                } else if t == "p" {
                    // 时钟校准：平板发来 p，回 bridge 当前单调微秒。
                    let _ = wr
                        .write_all(format!("#pong {}\n", crate::now_us()).as_bytes())
                        .await;
                } else if !t.is_empty() {
                    eprintln!("[touch] bad line: {line:?}");
                }
            }
        }
    }
    let _ = sent_cancel;
    // 断线时清空所有触点，避免 Mac 上留下按住不放的状态。
    let _ = tx
        .send(TouchEvent { kind: TouchKind::Cancel, id: 0, x: 0.0, y: 0.0 })
        .await;
    Ok(())
}

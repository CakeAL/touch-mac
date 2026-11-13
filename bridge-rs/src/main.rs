//! touchbridge：Sunshine → 原生多点触控 + H.264 中转（全 Rust，不依赖 moonlight-common-c）。
//!
//! 链路：/launch → RTSP(SETUP/ANNOUNCE/PLAY) → 控制流(ENet+GCM, 触摸) + 视频(UDP, 组帧)
//!       → 本地 TCP: 触控 47777 / 视频 47779 → `adb reverse` → 平板 App。
mod control;
mod launch;
mod relay;
mod rtsp;
mod touch;
mod video;

use anyhow::{anyhow, Result};
use bytes::Bytes;
use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::{broadcast, mpsc, watch};

use control::Cmd;
use touch::TouchEvent;

struct Args {
    host: String,
    appid: String,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
    cert: PathBuf,
    key: PathBuf,
    touch: SocketAddr,
    relay: SocketAddr,
    aspect: f32,
    no_cancel: bool,
}

fn parse_args() -> Result<Args> {
    let mut a = Args {
        host: "127.0.0.1".into(),
        appid: "881448767".into(),
        width: 1920,
        height: 1080,
        fps: 60,
        bitrate: 20000,
        cert: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../bridge/certs/client.crt")),
        key: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../bridge/certs/client.key")),
        touch: "127.0.0.1:47777".parse().unwrap(),
        relay: "127.0.0.1:47779".parse().unwrap(),
        aspect: 16.0 / 9.0,
        no_cancel: false,
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < argv.len() {
        let k = argv[i].as_str();
        let mut next = || {
            i += 1;
            argv.get(i).cloned().unwrap_or_default()
        };
        match k {
            "--host" => a.host = next(),
            "--appid" => a.appid = next(),
            "--width" => a.width = next().parse()?,
            "--height" => a.height = next().parse()?,
            "--fps" => a.fps = next().parse()?,
            "--bitrate" => a.bitrate = next().parse()?,
            "--cert" => a.cert = PathBuf::from(next()),
            "--key" => a.key = PathBuf::from(next()),
            "--touch" => a.touch = next().parse()?,
            "--relay" => a.relay = next().parse()?,
            "--aspect" => a.aspect = next().parse()?,
            "--no-cancel" => a.no_cancel = true,
            other => return Err(anyhow!("未知参数 {other}")),
        }
        i += 1;
    }
    Ok(a)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn rand_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut v))
        .expect("/dev/urandom");
    v
}

/// 把 RTSP 会话 URL（rtsp://host:port[/]）拆成 host/port。
fn parse_rtsp(url: &str) -> Result<(String, u16)> {
    let u = url.trim().strip_prefix("rtsp://").ok_or_else(|| anyhow!("bad session url {url}"))?;
    let hostport = u.split('/').next().unwrap_or(u);
    match hostport.rsplit_once(':') {
        Some((h, p)) => Ok((h.to_string(), p.parse()?)),
        None => Ok((hostport.to_string(), 48010)),
    }
}

/// 音视频 socket 的 500ms 保活 ping：同一个 socket 既发 ping 又收流。
async fn open_udp(addr: SocketAddr) -> Result<UdpSocket> {
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.connect(addr).await?;
    eprintln!("[ping] {addr} local {}", sock.local_addr()?);
    Ok(sock)
}

async fn audio_keepalive(addr: SocketAddr, payload: Option<[u8; 16]>) -> Result<()> {
    let sock = open_udp(addr).await?;
    let mut seq: u32 = 0;
    loop {
        let mut buf = [0u8; 20];
        let len = match &payload {
            Some(p) => {
                buf[..16].copy_from_slice(p);
                buf[16..].copy_from_slice(&seq.to_be_bytes());
                20
            }
            None => {
                buf[..4].copy_from_slice(b"PING");
                4
            }
        };
        seq = seq.wrapping_add(1);
        sock.send(&buf[..len]).await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let a = parse_args()?;

    let rikey_raw = rand_bytes(16);
    let rikey = hex(&rikey_raw);
    let rikeyid = u32::from_le_bytes(rand_bytes(4).try_into().unwrap());
    let rikeyid_s = rikeyid.to_string();
    let lp = launch::LaunchParams {
        host: &a.host,
        port: 47984,
        uniqueid: "0123456789ABCDEF",
        appid: &a.appid,
        width: a.width,
        height: a.height,
        fps: a.fps,
        bitrate_kbps: a.bitrate,
        rikey: &rikey,
        rikeyid: &rikeyid_s,
    };

    if !a.no_cancel {
        let _ = launch::cancel(&lp, &a.cert, &a.key);
        std::thread::sleep(Duration::from_millis(300));
    }
    let url = launch::launch(&lp, &a.cert, &a.key)?;
    eprintln!("[launch] session url = {url}");
    let (rh, rp) = parse_rtsp(&url)?;

    let mut rtsp = rtsp::Rtsp::new(&rh, rp);
    let opts = rtsp.options().await?;
    eprintln!("[rtsp] OPTIONS {}", opts.status);
    let desc = rtsp.describe().await?;
    eprintln!("[rtsp] DESCRIBE {}", desc.status);
    for l in desc.body.lines() {
        let l = l.trim();
        if l.contains("featureFlags") || l.contains("encryption") {
            eprintln!("[sdp] {l}");
        }
    }
    let (audio_port, audio_ping, _) = rtsp.setup("audio/0/0").await?;
    let (video_port, video_ping, _) = rtsp.setup("video/0/0").await?;
    let (ctrl_port, _, connect_data) = rtsp.setup("control/13/0").await?;
    eprintln!(
        "[rtsp] ports audio={audio_port} video={video_port} control={ctrl_port} connect={:?}",
        connect_data
    );

    let sdp = rtsp::build_sdp(video_port, a.width, a.height, a.fps, a.bitrate, &rh);
    let announce = rtsp.announce(&sdp).await?;
    if announce.status != 200 {
        return Err(anyhow!("ANNOUNCE -> {}: {}", announce.status, announce.body));
    }
    let play = rtsp.play().await?;
    eprintln!("[rtsp] PLAY {}", play.status);

    let host_ip: std::net::IpAddr = rh.parse().unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
    tokio::spawn(async move {
        if let Err(e) = audio_keepalive(SocketAddr::new(host_ip, audio_port), audio_ping).await {
            eprintln!("[audio] keepalive: {e}");
        }
    });

    let ctl = control::spawn(rh.clone(), ctrl_port, connect_data.unwrap_or(0), rikey_raw.try_into().unwrap())?;

    let (vt, _) = broadcast::channel(256);
    let (cfg_tx, cfg_rx) = watch::channel::<Option<Arc<Bytes>>>(None);
    {
        let vt = vt.clone();
        tokio::spawn(async move {
            if let Err(e) = video::run(SocketAddr::new(host_ip, video_port), video_ping, vt, cfg_tx).await {
                eprintln!("[video] 退出: {e}");
            }
        });
    }
    {
        let rx = vt.subscribe();
        let ctl = ctl.clone();
        let on_client = Arc::new(move || ctl.send(Cmd::RequestIdr));
        tokio::spawn(async move {
            if let Err(e) = relay::serve(a.relay, rx, cfg_rx, on_client).await {
                eprintln!("[relay] 退出: {e}");
            }
        });
    }
    // 定期请求关键帧，方便中途加入的客户端起播。
    {
        let ctl = ctl.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(5));
            loop {
                tick.tick().await;
                ctl.send(Cmd::RequestIdr);
            }
        });
    }
    let (ttx, mut trx) = mpsc::channel::<TouchEvent>(8192);
    {
        let ctl = ctl.clone();
        tokio::spawn(async move {
            while let Some(ev) = trx.recv().await {
                ctl.send(Cmd::Touch(ev));
            }
        });
    }
    tokio::spawn(async move {
        if let Err(e) = touch::serve(a.touch, ttx, a.aspect).await {
            eprintln!("[touch] 退出: {e}");
        }
    });

    eprintln!("[main] 就绪：触控 {} 视频 {}（Ctrl-C 结束）", a.touch, a.relay);
    tokio::signal::ctrl_c().await.ok();
    eprintln!("[main] 收尾");
    ctl.send(Cmd::Shutdown);
    let _ = launch::cancel(&lp, &a.cert, &a.key);
    Ok(())
}

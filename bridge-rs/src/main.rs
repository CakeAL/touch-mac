//! touchbridge：Sunshine → 原生多点触控 + H.264 中转（全 Rust，不依赖 moonlight-common-c）。
//!
//! 链路：/launch → RTSP(SETUP/ANNOUNCE/PLAY) → 控制流(ENet+GCM, 触摸) + 视频(UDP, 组帧)
//!       → 本地 TCP: 触控 47777 / 视频 47779 → `adb reverse` → 平板 App。
mod audio;
mod control;
mod control_port;
mod settings;
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

#[derive(Clone)]
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
    hevc: bool,
    hdr: bool,
    audio: bool,
    cfg_port: SocketAddr,
}

fn parse_args() -> Result<Args> {
    let st = settings::Settings::load();
    let mut a = Args {
        host: "127.0.0.1".into(),
        appid: "881448767".into(),
        width: st.width,
        height: st.height,
        fps: st.fps,
        bitrate: st.bitrate,
        cert: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/certs/client.crt")),
        key: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/certs/client.key")),
        touch: "127.0.0.1:47777".parse().unwrap(),
        relay: "127.0.0.1:47779".parse().unwrap(),
        aspect: 16.0 / 9.0,
        no_cancel: false,
        hevc: st.hevc,
        hdr: st.hdr,
        audio: st.audio,
        cfg_port: "127.0.0.1:47781".parse().unwrap(),
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
            "--hevc" => a.hevc = next() != "0",
            "--hdr" => a.hdr = next() != "0",
            "--no-hevc" => a.hevc = false,
            "--no-hdr" => a.hdr = false,
            "--audio" => a.audio = next() != "0",
            "--no-audio" => a.audio = false,
            "--cfg" => a.cfg_port = next().parse()?,
            other => return Err(anyhow!("未知参数 {other}")),
        }
        i += 1;
    }
    Ok(a)
}

/// 单调时钟微秒；relay 与 video 共用同一时间基准，供平板换算延时。
pub fn now_us() -> u64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_micros() as u64
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


type CtlSlot = Arc<std::sync::Mutex<Option<control::ControlHandle>>>;

fn request_idr(slot: &CtlSlot) {
    if let Some(c) = slot.lock().unwrap().as_ref() {
        c.send(Cmd::RequestIdr);
    }
}

/// Sunshine 可能没在跑（或刚被退出）：先探 47984，不在就 `open -a` 唤醒并等它就绪。
async fn ensure_sunshine() -> Result<()> {
    let probe = || async {
        tokio::time::timeout(
            Duration::from_millis(300),
            tokio::net::TcpStream::connect("127.0.0.1:47984"),
        )
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
    };
    if probe().await {
        return Ok(());
    }
    eprintln!("[sunshine] 未在运行，唤醒 /Applications/Sunshine.app");
    let _ = std::process::Command::new("open")
        .args(["-a", "/Applications/Sunshine.app"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
    for _ in 0..60 {
        tokio::time::sleep(Duration::from_millis(250)).await;
        if probe().await {
            eprintln!("[sunshine] 已就绪");
            return Ok(());
        }
    }
    Err(anyhow!("唤醒 Sunshine 超时（47984 未就绪）"))
}

/// 一次串流会话：/launch → RTSP → 控制流/视频/音频。客户端全部断开时由外部置 stop。
async fn run_session(
    a: Args,
    vtx: broadcast::Sender<relay::VideoMsg>,
    atx: broadcast::Sender<Arc<audio::AudioPacket>>,
    cfg_tx: watch::Sender<Option<Arc<Bytes>>>,
    slot: CtlSlot,
    mut stop: watch::Receiver<bool>,
) -> Result<()> {
    ensure_sunshine().await?;

    let rikey_raw = rand_bytes(16);
    let rikey = hex(&rikey_raw);
    let rikeyid = u32::from_le_bytes(rand_bytes(4).try_into().unwrap()).to_string();
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
        rikeyid: &rikeyid,
    };

    if !a.no_cancel {
        let _ = launch::cancel(&lp, &a.cert, &a.key);
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    let url = launch::launch(&lp, &a.cert, &a.key)?;
    eprintln!("[launch] session url = {url}");
    let (rh, rp) = parse_rtsp(&url)?;

    let mut rtsp = rtsp::Rtsp::new(&rh, rp);
    let opts = rtsp.options().await?;
    eprintln!("[rtsp] OPTIONS {}", opts.status);
    let desc = rtsp.describe().await?;
    eprintln!("[rtsp] DESCRIBE {}", desc.status);
    let (audio_port, audio_ping, _) = rtsp.setup("audio/0/0").await?;
    let (video_port, video_ping, _) = rtsp.setup("video/0/0").await?;
    let (ctrl_port, _, connect_data) = rtsp.setup("control/13/0").await?;
    eprintln!(
        "[rtsp] ports audio={audio_port} video={video_port} control={ctrl_port} connect={:?}",
        connect_data
    );

    eprintln!(
        "[cfg] {}x{}@{} {}kbps hevc={} hdr={} audio={}",
        a.width, a.height, a.fps, a.bitrate, a.hevc, a.hdr, a.audio
    );
    let sdp = rtsp::build_sdp(video_port, a.width, a.height, a.fps, a.bitrate, &rh, a.hevc, a.hdr);
    let announce = rtsp.announce(&sdp).await?;
    if announce.status != 200 {
        return Err(anyhow!("ANNOUNCE -> {}: {}", announce.status, announce.body));
    }
    let play = rtsp.play().await?;
    eprintln!("[rtsp] PLAY {}", play.status);

    let host_ip: std::net::IpAddr = rh
        .parse()
        .unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));

    let ctl = control::spawn(rh.clone(), ctrl_port, connect_data.unwrap_or(0), rikey_raw.clone().try_into().unwrap())?;
    *slot.lock().unwrap() = Some(ctl.clone());

    let audio_task = tokio::spawn({
        let atx = atx.clone();
        async move {
            if let Err(e) = audio::run(SocketAddr::new(host_ip, audio_port), audio_ping, atx).await {
                eprintln!("[audio] 退出: {e}");
            }
        }
    });
    let video_task = tokio::spawn({
        let vtx = vtx.clone();
        let cfg_tx = cfg_tx.clone();
        let loss_ctl = ctl.clone();
        async move {
            let on_loss = Arc::new(move || loss_ctl.send(crate::control::Cmd::RequestIdr));
            if let Err(e) = video::run(SocketAddr::new(host_ip, video_port), video_ping, vtx, cfg_tx, on_loss).await {
                eprintln!("[video] 退出: {e}");
            }
        }
    });
    // 定期请求关键帧，方便中途加入的客户端起播。
    let idr_task = tokio::spawn({
        let ctl = ctl.clone();
        async move {
            let mut tick = tokio::time::interval(Duration::from_secs(5));
            tick.tick().await;
            loop {
                tick.tick().await;
                ctl.send(Cmd::RequestIdr);
            }
        }
    });

    // 会话结束条件：外部 stop（客户端全走）或服务端断流（控制流断）。
    let mut idle = tokio::time::interval(Duration::from_millis(500));
    loop {
        tokio::select! {
            _ = idle.tick() => {
                if !ctl.alive() {
                    eprintln!("[session] 控制流已断开，结束会话");
                    break;
                }
            }
            r = stop.changed() => {
                if r.is_err() || *stop.borrow() {
                    eprintln!("[session] 客户端已全部断开，结束会话");
                    break;
                }
            }
            _ = tokio::signal::ctrl_c() => {
                eprintln!("[session] Ctrl-C");
                break;
            }
        }
    }

    idr_task.abort();
    video_task.abort();
    audio_task.abort();
    ctl.send(Cmd::Shutdown);
    tokio::time::sleep(Duration::from_millis(200)).await;
    *slot.lock().unwrap() = None;
    if !a.no_cancel {
        let _ = launch::cancel(&lp, &a.cert, &a.key);
    }
    {
        let mut w = cfg_tx.subscribe();
        let _ = w.borrow_and_update();
        let _ = cfg_tx.send(None);
    }
    eprintln!("[session] 已结束");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let a = parse_args()?;
    let effective = settings::Settings {
        width: a.width,
        height: a.height,
        fps: a.fps,
        bitrate: a.bitrate,
        hevc: a.hevc,
        hdr: a.hdr,
        audio: a.audio,
    };
    let _ = effective.save();
    {
        let eff = effective.clone();
        tokio::spawn(async move {
            if let Err(e) = control_port::serve(SocketAddr::from(([127, 0, 0, 1], 47781)), eff).await {
                eprintln!("[cfg] 退出: {e}");
            }
        });
    }

    // 常驻通道：跨会话复用，平板的视频连接不必随会话重建。
    let (vtx, _) = broadcast::channel::<relay::VideoMsg>(256);
    let (atx, _) = broadcast::channel::<Arc<audio::AudioPacket>>(512);
    let (cfg_tx, cfg_rx) = watch::channel::<Option<Arc<Bytes>>>(None);
    let slot: CtlSlot = Arc::new(std::sync::Mutex::new(None));
    let (clients_tx, mut clients_rx) = watch::channel::<usize>(0);
    let (idr_tx, mut idr_rx) = watch::channel::<u64>(0);

    {
        let vrx = vtx.subscribe();
        let arx = atx.subscribe();
        let slot = slot.clone();
        let on_client = Arc::new(move || request_idr(&slot));
        tokio::spawn(async move {
            if let Err(e) = relay::serve(a.relay, vrx, cfg_rx, arx, a.audio, on_client).await {
                eprintln!("[relay] 退出: {e}");
            }
        });
    }
    let (ttx, mut trx) = mpsc::channel::<TouchEvent>(8192);
    {
        let slot = slot.clone();
        tokio::spawn(async move {
            while let Some(ev) = trx.recv().await {
                if let Some(c) = slot.lock().unwrap().as_ref() {
                    c.send(Cmd::Touch(ev));
                }
            }
        });
    }
    {
        let aspect = a.aspect;
        let touch_addr = a.touch;
        tokio::spawn(async move {
            if let Err(e) = touch::serve(touch_addr, ttx, aspect, clients_tx, idr_tx).await {
                eprintln!("[touch] 退出: {e}");
            }
        });
    }

    eprintln!("[main] 就绪：触控 {} 视频 {}（等平板连接后再唤醒 Sunshine）", a.touch, a.relay);

    let mut session: Option<(tokio::task::JoinHandle<()>, watch::Sender<bool>)> = None;
    loop {
        tokio::select! {
            _ = clients_rx.changed() => {}
            _ = idr_rx.changed() => {
                // 平板端明确要求关键帧（例如解码器丢了参考帧）
                request_idr(&slot);
            }
            _ = tokio::signal::ctrl_c() => break,
            _ = tokio::time::sleep(Duration::from_millis(300)) => {}
        }
        let n = *clients_rx.borrow();
        let finished = session.as_ref().map(|(h, _)| h.is_finished()).unwrap_or(false);
        if finished {
            session = None;
            eprintln!("[main] 会话已结束，回到待机");
        }
        if n > 0 && session.is_none() {
            let (stop_tx, stop_rx) = watch::channel(false);
            let a2 = a.clone();
            let (vtx2, atx2, cfg2, slot2) = (vtx.clone(), atx.clone(), cfg_tx.clone(), slot.clone());
            let h = tokio::spawn(async move {
                if let Err(e) = run_session(a2, vtx2, atx2, cfg2, slot2, stop_rx).await {
                    eprintln!("[session] 失败: {e}");
                }
            });
            eprintln!("[main] 平板已连接，开始会话");
            session = Some((h, stop_tx));
        } else if n == 0 {
            if let Some((_, stop_tx)) = session.as_ref() {
                // 给平板 3 秒重连窗口（App 切后台/旋转都会断一下）。
                tokio::time::sleep(Duration::from_secs(3)).await;
                if *clients_rx.borrow() == 0 {
                    let _ = stop_tx.send(true);
                }
            }
        }
    }

    if let Some((h, stop_tx)) = session.take() {
        let _ = stop_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(3), h).await;
    }
    eprintln!("[main] 退出");
    Ok(())
}

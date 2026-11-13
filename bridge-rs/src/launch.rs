//! HTTPS /launch 客户端：取 RTSP 会话 URL。
use anyhow::{anyhow, Context, Result};
use std::fs;
use std::path::Path;

pub struct LaunchParams<'a> {
    pub host: &'a str,
    pub port: u16,
    pub uniqueid: &'a str,
    pub appid: &'a str,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub rikey: &'a str,
    pub rikeyid: &'a str,
}

fn client(cert_path: &Path, key_path: &Path) -> Result<reqwest::blocking::Client> {
    let mut pem = fs::read(cert_path).context("read client cert")?;
    pem.extend_from_slice(b"\n");
    pem.extend_from_slice(&fs::read(key_path).context("read client key")?);
    let identity = reqwest::Identity::from_pem(&pem).context("client identity pem")?;
    Ok(reqwest::blocking::Client::builder()
        .use_rustls_tls()
        .danger_accept_invalid_certs(true)
        .identity(identity)
        .timeout(std::time::Duration::from_secs(15))
        .build()?)
}

/// 取消该 uniqueid 上正在跑的会话（服务端会 200 + <cancel>1</cancel>）。
pub fn cancel(p: &LaunchParams, cert_path: &Path, key_path: &Path) -> Result<()> {
    let c = client(cert_path, key_path)?;
    let url = format!("https://{}:{}/cancel?uniqueid={}", p.host, p.port, p.uniqueid);
    let body = c.get(&url).send().context("GET /cancel")?.text()?;
    eprintln!("[launch] cancel -> {}", body.replace('\n', " ").trim());
    Ok(())
}

pub fn launch(p: &LaunchParams, cert_path: &Path, key_path: &Path) -> Result<String> {
    let client = client(cert_path, key_path)?;
    let url = format!(
        "https://{}:{}/launch?uniqueid={}&appid={}&mode={}x{}x{}&fps={}&hdrMode=0&rikey={}&rikeyid={}\
         &localAudioPlayMode=0&surroundAudioInfo=196610&sops=0&corever=0&gcmap=0&clientHdrCapVersion=0\
         &maxFPS={}&bitrate={}",
        p.host, p.port, p.uniqueid, p.appid, p.width, p.height, p.fps, p.fps,
        p.rikey, p.rikeyid, p.fps, p.bitrate_kbps
    );
    let body = client.get(&url).send().context("GET /launch")?.text()?;

    if let Some(status) = extract(&body, "status_code") {
        if status != "200" {
            return Err(anyhow!("launch failed: {}", body[..body.len().min(400)].to_string()));
        }
    }
    extract(&body, "sessionUrl0").ok_or_else(|| anyhow!("no sessionUrl0 in {}", &body[..body.len().min(400)]))
}

fn extract(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{}>", tag);
    let close = format!("</{}>", tag);
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&close)? + start;
    Some(xml[start..end].to_string())
}

//! 最小 RTSP 客户端：每条请求一个 TCP 连接，读到 FIN 为止（Sunshine 行为）。
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub struct Rtsp {
    pub host: String,
    pub port: u16,
    pub cseq: u32,
    pub session: Option<String>,
    pub version: u32,
}

pub struct Response {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: String,
}

impl Rtsp {
    pub fn new(host: &str, port: u16) -> Self {
        Rtsp { host: host.to_string(), port, cseq: 1, session: None, version: 14 }
    }

    async fn transact(&mut self, request: &str) -> Result<Response> {
        let mut sock = TcpStream::connect((self.host.as_str(), self.port)).await?;
        sock.set_nodelay(true).ok();
        sock.write_all(request.as_bytes()).await?;
        sock.flush().await?;
        let mut buf = Vec::with_capacity(8192);
        sock.read_to_end(&mut buf).await?;
        let text = String::from_utf8_lossy(&buf).to_string();
        let (head, body) = match text.find("\r\n\r\n") {
            Some(i) => (&text[..i], text[i + 4..].to_string()),
            None => (text.as_str(), String::new()),
        };
        let mut lines = head.split("\r\n");
        let status_line = lines.next().unwrap_or("");
        let status: u16 = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow!("bad RTSP status line: {status_line:?}"))?;
        let mut headers = HashMap::new();
        for l in lines {
            if l.is_empty() {
                continue;
            }
            if let Some((k, v)) = l.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }
        Ok(Response { status, headers, body })
    }

    fn common(&mut self, mut s: String) -> String {
        s.push_str(&format!("CSeq: {}\r\nX-GS-ClientVersion: {}\r\n", self.cseq, self.version));
        self.cseq += 1;
        s
    }

    pub async fn options(&mut self) -> Result<Response> {
        let url = format!("rtsp://{}:{}", self.host, self.port);
        let req = self.common(format!("OPTIONS {url} RTSP/1.0\r\n"));
        let req = format!("{req}Host: {}\r\n\r\n", self.host);
        self.transact(&req).await
    }

    pub async fn describe(&mut self) -> Result<Response> {
        let url = format!("rtsp://{}:{}", self.host, self.port);
        let req = self.common(format!(
            "DESCRIBE {url} RTSP/1.0\r\nAccept: application/sdp\r\n"
        ));
        let req = format!("{req}Host: {}\r\n\r\n", self.host);
        self.transact(&req).await
    }

    /// SETUP；返回 (server_port, ping_payload, connect_data)。
    pub async fn setup(&mut self, stream: &str) -> Result<(u16, Option<[u8; 16]>, Option<u32>)> {
        let sess = match &self.session {
            Some(s) => format!("Session: {s}\r\n"),
            None => String::new(),
        };
        let req = self.common(format!("SETUP streamid={stream} RTSP/1.0\r\n{sess}"));
        let req = format!(
            "{req}Host: {}\r\nTransport: unicast;X-GS-ClientPort=50000-50001\r\n\r\n",
            self.host
        );
        let resp = self.transact(&req).await?;
        if resp.status != 200 {
            return Err(anyhow!("SETUP {stream} -> {}", resp.status));
        }
        if self.session.is_none() {
            if let Some(s) = resp.headers.get("session") {
                self.session = Some(s.split(';').next().unwrap_or(s).trim().to_string());
            }
        }
        let port = resp
            .headers
            .get("transport")
            .and_then(|t| t.split("server_port=").nth(1))
            .and_then(|v| v.split_whitespace().next())
            .and_then(|v| v.trim_end_matches(';').parse::<u16>().ok())
            .unwrap_or(47998);

        let mut ping = None;
        if let Some(p) = resp.headers.get("x-ss-ping-payload") {
            if p.len() == 16 {
                let mut out = [0u8; 16];
                out.copy_from_slice(p.as_bytes());
                ping = Some(out);
            }
        }
        let connect = resp
            .headers
            .get("x-ss-connect-data")
            .and_then(|v| v.parse::<u32>().ok());
        Ok((port, ping, connect))
    }

    pub async fn announce(&mut self, sdp: &str) -> Result<Response> {
        let sess = self.session.clone().unwrap_or_default();
        let req = self.common(format!(
            "ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nSession: {sess}\r\nContent-type: application/sdp\r\nContent-length: {}\r\n",
            sdp.len()
        ));
        let req = format!("{req}Host: {}\r\n\r\n{sdp}", self.host);
        self.transact(&req).await
    }

    pub async fn play(&mut self) -> Result<Response> {
        let sess = self.session.clone().unwrap_or_default();
        let req = self.common(format!("PLAY / RTSP/1.0\r\nSession: {sess}\r\n"));
        let req = format!("{req}Host: {}\r\n\r\n", self.host);
        self.transact(&req).await
    }
}

/// 生成 ANNOUNCE 的 SDP（照抄 SdpGenerator 的顺序与“行尾多一个空格”怪癖）。
pub fn build_sdp(
    video_port: u16,
    width: u32,
    height: u32,
    fps: u32,
    bitrate_kbps: u32,
    host: &str,
    hevc: bool,
    hdr: bool,
) -> String {
    let mut s = String::new();
    s.push_str("v=0\r\n");
    s.push_str(&format!("o=android 0 14 IN IPv4 {host}\r\n"));
    s.push_str("s=NVIDIA Streaming Client\r\n");
    let bw = bitrate_kbps.to_string();
    let hevc_support = if hevc { "1" } else { "0" };
    let bitstream = if hevc { "1" } else { "0" };
    let dr_mode = if hdr { "1" } else { "0" };
    let attrs: Vec<(&str, String)> = vec![
        ("x-ml-general.featureFlags", "3".into()),
        ("x-ss-general.encryptionEnabled", "1".into()),
        ("x-ss-video[0].chromaSamplingType", "0".into()),
        ("x-ss-video[0].intraRefresh", "0".into()),
        ("x-nv-video[0].clientViewportWd", width.to_string()),
        ("x-nv-video[0].clientViewportHt", height.to_string()),
        ("x-nv-video[0].maxFPS", fps.to_string()),
        ("x-nv-video[0].packetSize", "1392".into()),
        ("x-nv-video[0].rateControlMode", "4".into()),
        ("x-nv-video[0].timeoutLengthMs", "7000".into()),
        ("x-nv-video[0].framesWithInvalidRefThreshold", "0".into()),
        ("x-nv-video[0].initialBitrateKbps", bw.clone()),
        ("x-nv-video[0].initialPeakBitrateKbps", bw.clone()),
        ("x-nv-vqos[0].bw.minimumBitrateKbps", bw.clone()),
        ("x-nv-vqos[0].bw.maximumBitrateKbps", bw.clone()),
        ("x-ml-video.configuredBitrateKbps", bitrate_kbps.to_string()),
        ("x-nv-vqos[0].fec.enable", "1".into()),
        ("x-nv-vqos[0].videoQualityScoreUpdateTime", "5000".into()),
        ("x-nv-vqos[0].qosTrafficType", "5".into()),
        ("x-nv-aqos.qosTrafficType", "4".into()),
        ("x-nv-general.featureFlags", "135".into()),
        ("x-nv-general.useReliableUdp", "13".into()),
        ("x-nv-vqos[0].fec.minRequiredFecPackets", "2".into()),
        ("x-nv-vqos[0].bllFec.enable", "0".into()),
        ("x-nv-vqos[0].drc.enable", "0".into()),
        ("x-nv-general.enableRecoveryMode", "0".into()),
        ("x-nv-video[0].videoEncoderSlicesPerFrame", "1".into()),
        ("x-nv-clientSupportHevc", hevc_support.into()),
        ("x-nv-vqos[0].bitStreamFormat", bitstream.into()),
        ("x-nv-video[0].dynamicRangeMode", dr_mode.into()),
        ("x-nv-video[0].maxNumReferenceFrames", "0".into()),
        ("x-nv-video[0].clientRefreshRateX100", (fps * 100).to_string()),
        ("x-nv-audio.surround.numChannels", "2".into()),
        ("x-nv-audio.surround.channelMask", "3".into()),
        ("x-nv-audio.surround.enable", "0".into()),
        ("x-nv-audio.surround.AudioQuality", "0".into()),
        ("x-nv-aqos.packetDuration", "5".into()),
        (
            "x-nv-video[0].encoderCscMode",
            // 0=Rec.601 limited；2 会让平板解出整体偏绿的画面（实测），所以默认 0。
            std::env::var("CSC").unwrap_or_else(|_| "0".into()),
        ),
    ];
    for (k, v) in attrs {
        s.push_str(&format!("a={k}:{v} \r\n"));
    }
    s.push_str("t=0 0\r\n");
    s.push_str(&format!("m=video {video_port}  \r\n"));
    s
}

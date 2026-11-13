//! 会话参数：命令行 / 设置文件 / 平板设置界面（控制口 47781）三个来源。
//!
//! 优先级：命令行 > 设置文件 > 内置默认值。平板上点「应用」时，控制口把参数写回
//! 设置文件，然后重新 exec 自己（端口监听的代码路径简单，不必在进程内热切换会话）。
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Settings {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate: u32,
    pub hevc: bool,
    pub hdr: bool,
    pub audio: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { width: 1920, height: 1080, fps: 120, bitrate: 40000, hevc: true, hdr: true, audio: true }
    }
}

pub fn path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".config/touchbridge/settings")
}

impl Settings {
    pub fn load() -> Settings {
        let mut s = Settings::default();
        let p = path();
        if let Ok(text) = std::fs::read_to_string(&p) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                if let Some((k, v)) = line.split_once('=') {
                    s.set(k.trim(), v.trim());
                }
            }
        }
        s
    }

    pub fn save(&self) -> std::io::Result<()> {
        let p = path();
        if let Some(dir) = p.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(p, self.to_text())
    }

    pub fn to_text(&self) -> String {
        format!(
            "width={}\nheight={}\nfps={}\nbitrate={}\nhevc={}\nhdr={}\naudio={}\n",
            self.width,
            self.height,
            self.fps,
            self.bitrate,
            if self.hevc { 1 } else { 0 },
            if self.hdr { 1 } else { 0 },
            if self.audio { 1 } else { 0 }
        )
    }

    pub fn one_line(&self) -> String {
        self.to_text().trim().replace('\n', " ")
    }

    /// 接受 `width=1920` 这类单个键值；返回是否为已知键。
    pub fn set(&mut self, k: &str, v: &str) -> bool {
        match k {
            "width" => match v.parse() {
                Ok(n) => { self.width = n; true }
                Err(_) => false,
            },
            "height" => match v.parse() {
                Ok(n) => { self.height = n; true }
                Err(_) => false,
            },
            "fps" => match v.parse() {
                Ok(n) => { self.fps = n; true }
                Err(_) => false,
            },
            "bitrate" => match v.parse() {
                Ok(n) => { self.bitrate = n; true }
                Err(_) => false,
            },
            "hevc" => { self.hevc = v != "0" && !v.eq_ignore_ascii_case("false"); true }
            "hdr" => { self.hdr = v != "0" && !v.eq_ignore_ascii_case("false"); true }
            "audio" => { self.audio = v != "0" && !v.eq_ignore_ascii_case("false"); true }
            _ => false,
        }
    }

    /// 供 exec 用的命令行参数（保持既有 CLI 形式）。
    pub fn argv(&self) -> Vec<String> {
        vec![
            "--width".into(), self.width.to_string(),
            "--height".into(), self.height.to_string(),
            "--fps".into(), self.fps.to_string(),
            "--bitrate".into(), self.bitrate.to_string(),
            "--hevc".into(), if self.hevc { "1".into() } else { "0".into() },
            "--hdr".into(), if self.hdr { "1".into() } else { "0".into() },
            "--audio".into(), if self.audio { "1".into() } else { "0".into() },
        ]
    }
}

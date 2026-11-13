//! 会话参数：命令行 / 设置文件 / 平板设置界面（控制口 47781）三个来源。
//!
//! 优先级：命令行 > 设置文件 > 内置默认值。平板上点「应用」时，控制口把参数写回
//! 设置文件，然后重新 exec 自己（端口监听的代码路径简单，不必在进程内热切换会话）。
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Settings {
    /// 分辨率档位（按高度）：1080 / 1440 / 2160。实际宽度由屏幕比例自动算。
    pub res: u32,
    /// 平板屏幕尺寸（像素），由 App 连上来时上报；未知时按 16:9。
    pub screen_w: u32,
    pub screen_h: u32,
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
        Settings {
            res: 1080,
            screen_w: 0,
            screen_h: 0,
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 60000,
            hevc: true,
            hdr: false,
            audio: true,
        }
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

    /// 按「档位高度 + 屏幕比例」算出实际编码尺寸（宽度取偶数）。
    pub fn size(&self) -> (u32, u32) {
        size_for(self.res, if self.screen_w > 0 && self.screen_h > 0 {
            Some((self.screen_w, self.screen_h))
        } else {
            None
        })
    }

    pub fn apply_size(&mut self) {
        let (w, h) = self.size();
        self.width = w;
        self.height = h;
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
            "res={}\nscreen={}x{}\nfps={}\nbitrate={}\nhevc={}\nhdr={}\naudio={}\n",
            self.res,
            self.screen_w,
            self.screen_h,
            self.fps,
            self.bitrate,
            if self.hevc { 1 } else { 0 },
            if self.hdr { 1 } else { 0 },
            if self.audio { 1 } else { 0 }
        )
    }

    pub fn one_line(&self) -> String {
        let (w, h) = self.size();
        format!("{} size={w}x{h}", self.to_text().trim().replace('\n', " "))
    }

    /// 接受 `width=1920` 这类单个键值；返回是否为已知键。
    pub fn set(&mut self, k: &str, v: &str) -> bool {
        match k {
            "res" => match parse_res(v) {
                Some(r) => { self.res = r; self.apply_size(); true }
                None => false,
            },
            "screen" => match v.split_once('x').and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?))) {
                Some((w, h)) if w > 0 && h > 0 => {
                    self.screen_w = w;
                    self.screen_h = h;
                    self.apply_size();
                    true
                }
                _ => false,
            },
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
        let (w, h) = self.size();
        vec![
            "--res".into(), self.res.to_string(),
            "--width".into(), w.to_string(),
            "--height".into(), h.to_string(),
            "--fps".into(), self.fps.to_string(),
            "--bitrate".into(), self.bitrate.to_string(),
            "--hevc".into(), if self.hevc { "1".into() } else { "0".into() },
            "--hdr".into(), if self.hdr { "1".into() } else { "0".into() },
            "--audio".into(), if self.audio { "1".into() } else { "0".into() },
        ]
    }
}

/// `1080` / `1080p` / `2k` / `2K` / `4k` 都接受；返回的是「高度档位」。
pub fn parse_res(v: &str) -> Option<u32> {
    let t = v.trim().to_ascii_lowercase();
    let t = t.trim_end_matches('p');
    match t {
        "1080" | "fhd" => Some(1080),
        "1440" | "2k" | "qhd" => Some(1440),
        "2160" | "4k" | "uhd" => Some(2160),
        // 0 = 点对点：直接用平板屏幕像素，不缩放。
        "0" | "native" | "point" | "dpad" => Some(0),
        _ => t.parse::<u32>().ok().filter(|n| *n >= 480 && *n <= 4320),
    }
}

/// 给定档位高度与屏幕比例，算出编码尺寸；宽度补成偶数（编码器要求）。
pub fn size_for(res: u32, screen: Option<(u32, u32)>) -> (u32, u32) {
    // res == 0：点对点，直接编平板原生像素（偶数对齐），平板不需要再缩放。
    if res == 0 {
        if let Some((w, h)) = screen {
            if w > 0 && h > 0 {
                // 编码器要求 16 对齐（2800 可以，1752 不行 → 1744）。
                return (w & !15, h & !15);
            }
        }
        return (1920, 1080);
    }
    let aspect = match screen {
        Some((w, h)) if w > 0 && h > 0 => w as f64 / h as f64,
        _ => 16.0 / 9.0,
    };
    let w = (res as f64 * aspect).round() as u32;
    ((w + 1) & !1, res)
}

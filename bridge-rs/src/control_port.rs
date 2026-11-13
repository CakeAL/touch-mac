//! 平板设置界面用的控制口（TCP 47781，经 adb reverse 打到本地）。
//!
//! 行协议：
//!   get                → `#cfg width=1920 height=1080 fps=120 ...`
//!   set <key>=<value>  → 暂存，回 `#ok <key>=<value>`
//!   apply              → 写设置文件并重新 exec 自己（新参数生效）
//!
//! 之所以用“重新 exec”而不是热切换：会话、UDP 端口和编码器都绑定在一次 /launch 上，
//! 重建整条链比在进程内拆装更可靠，平板端只是断线 1 秒后重连。
use crate::settings::Settings;
use std::net::SocketAddr;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

pub async fn serve(addr: SocketAddr, current: Settings) -> anyhow::Result<()> {
    let listener = TcpListener::bind(addr).await?;
    eprintln!("[cfg] 设置口 {} （get / set k=v / apply）", addr);
    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[cfg] accept: {e}");
                continue;
            }
        };
        let cur = current.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(sock, cur).await {
                eprintln!("[cfg] {peer}: {e}");
            }
        });
    }
}

async fn handle(sock: TcpStream, current: Settings) -> anyhow::Result<()> {
    let (rd, mut wr) = sock.into_split();
    let mut pending = current.clone();
    let mut lines = BufReader::new(rd).lines();
    let _ = wr.write_all(format!("#cfg {}\n", pending.one_line()).as_bytes()).await;
    while let Some(line) = lines.next_line().await? {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        let mut it = line.splitn(2, ' ');
        let cmd = it.next().unwrap_or("");
        let arg = it.next().unwrap_or("").trim().to_string();
        match cmd {
            "get" => {
                let _ = wr.write_all(format!("#cfg {}\n", pending.one_line()).as_bytes()).await;
            }
            "set" => {
                if let Some((k, v)) = arg.split_once('=') {
                    if pending.set(k.trim(), v.trim()) {
                        let _ = wr.write_all(format!("#ok {k}={v}\n").as_bytes()).await;
                    } else {
                        let _ = wr.write_all(format!("#err 未知键 {k}\n").as_bytes()).await;
                    }
                }
            }
            "apply" => {
                if let Err(e) = pending.save() {
                    let _ = wr.write_all(format!("#err 保存失败 {e}\n").as_bytes()).await;
                    continue;
                }
                let _ = wr.write_all(b"#applied\n").await;
                let _ = wr.flush().await;
                eprintln!("[cfg] 应用新设置：{}", pending.one_line());
                respawn(&pending);
            }
            other => {
                let _ = wr.write_all(format!("#err 未知命令 {other}\n").as_bytes()).await;
            }
        }
    }
    Ok(())
}

/// 用新参数重启自己；旧进程退出后新进程会重新绑定端口。
fn respawn(s: &Settings) -> ! {
    let exe = std::env::current_exe().unwrap_or_else(|_| "touchbridge".into());
    let _ = std::process::Command::new(exe).args(s.argv()).spawn();
    println!("[cfg] 已启动新进程，旧进程退出");
    std::process::exit(0);
}

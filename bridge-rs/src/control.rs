//! 控制流：ENet（vendored C 库）+ AES-128-GCM 信封（SS_ENC_CONTROL_V2）。
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use anyhow::{anyhow, Result};
use std::ffi::c_void;
use std::os::raw::{c_char, c_int};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use crate::touch::{TouchEvent, TouchKind};

#[repr(C)]
struct TbEvent {
    type_: c_int,
    peer: *mut c_void,
    channel: c_int,
    len: c_int,
}

extern "C" {
    fn tb_init() -> c_int;
    fn tb_host_create(peers: c_int, channels: c_int) -> *mut c_void;
    fn tb_connect(host: *mut c_void, ip: *const c_char, port: u16, channels: c_int, connect_data: u32, out_peer: *mut *mut c_void) -> c_int;
    fn tb_service(host: *mut c_void, timeout_ms: c_int, ev: *mut TbEvent, buf: *mut u8, buflen: c_int) -> c_int;
    fn tb_send(peer: *mut c_void, channel: c_int, data: *const u8, len: c_int, reliable: c_int) -> c_int;
    fn tb_flush(host: *mut c_void);
    fn tb_peer_state(peer: *mut c_void) -> c_int;
    fn tb_destroy(host: *mut c_void);
}

const TYPE_INPUT: u16 = 0x0206;
const TYPE_PING: u16 = 0x0200;
const TYPE_IDR: u16 = 0x0302;
const TYPE_START_A: u16 = 0x0305;
const TYPE_START_B: u16 = 0x0307;
const TYPE_TERMINATE: u16 = 0x0109;

const CH_TOUCH: c_int = 5;
const CH_GENERIC: c_int = 0;

pub enum Cmd {
    Touch(TouchEvent),
    RequestIdr,
    Shutdown,
}

#[derive(Clone)]
pub struct ControlHandle {
    tx: Sender<Cmd>,
}

impl ControlHandle {
    pub fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }
}

pub fn spawn(host_ip: String, port: u16, connect_data: u32, key: [u8; 16]) -> Result<ControlHandle> {
    let (tx, rx) = channel::<Cmd>();
    std::thread::Builder::new()
        .name("control".into())
        .spawn(move || {
            if let Err(e) = run(&host_ip, port, connect_data, key, rx) {
                eprintln!("[ctl] 退出: {e}");
            }
        })?;
    Ok(ControlHandle { tx })
}

struct Crypt {
    key: [u8; 16],
    seq: u32,
}

impl Crypt {
    fn nonce(&self, seq: u32, dir_byte: u8) -> [u8; 12] {
        let mut iv = [0u8; 12];
        iv[..4].copy_from_slice(&seq.to_le_bytes());
        iv[10] = dir_byte;
        iv[11] = b'C';
        iv
    }

    /// 生成加密信封：type(2) len(2) seq(4) tag(16) ciphertext。
    fn seal(&mut self, msg_type: u16, payload: &[u8]) -> Vec<u8> {
        let inner_len = 4 + payload.len();
        let mut inner = Vec::with_capacity(inner_len);
        inner.extend_from_slice(&msg_type.to_le_bytes());
        inner.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        inner.extend_from_slice(payload);

        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        let cipher = Aes128Gcm::new_from_slice(&self.key).expect("key");
        let nonce = self.nonce(seq, b'C');
        let mut out = cipher
            .encrypt(Nonce::from_slice(&nonce), inner.as_slice())
            .expect("encrypt");
        let tag = out.split_off(out.len() - 16);

        let mut env = Vec::with_capacity(8 + 16 + out.len());
        env.extend_from_slice(&1u16.to_le_bytes());
        env.extend_from_slice(&((4 + 16 + out.len()) as u16).to_le_bytes());
        env.extend_from_slice(&seq.to_le_bytes());
        env.extend_from_slice(&tag);
        env.extend_from_slice(&out);
        env
    }

    fn open(&self, buf: &[u8]) -> Option<(u16, Vec<u8>)> {
        if buf.len() < 24 {
            return None;
        }
        let len = u16::from_le_bytes([buf[2], buf[3]]) as usize;
        if buf.len() < 4 + len {
            return None;
        }
        let seq = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let tag = &buf[8..24];
        let ct = &buf[24..4 + len];
        let mut ct_tag = Vec::with_capacity(ct.len() + 16);
        ct_tag.extend_from_slice(ct);
        ct_tag.extend_from_slice(tag);
        let cipher = Aes128Gcm::new_from_slice(&self.key).ok()?;
        let nonce = self.nonce(seq, b'H');
        let plain = cipher.decrypt(Nonce::from_slice(&nonce), ct_tag.as_slice()).ok()?;
        let ty = u16::from_le_bytes([plain[0], plain[1]]);
        Some((ty, plain[4..].to_vec()))
    }
}

fn touch_payload(ev: &TouchEvent) -> Vec<u8> {
    let (etype, x, y) = match ev.kind {
        TouchKind::Down => (1u8, ev.x, ev.y),
        TouchKind::Up => (2u8, ev.x, ev.y),
        TouchKind::Move => (3u8, ev.x, ev.y),
        TouchKind::Cancel => (7u8, 0.0, 0.0),
    };
    let mut b = [0u8; 36];
    b[0..4].copy_from_slice(&32u32.to_be_bytes());
    b[4..8].copy_from_slice(&0x5500_0002u32.to_le_bytes());
    b[8] = etype;
    b[9] = 0;
    b[10..12].copy_from_slice(&0u16.to_le_bytes());
    b[12..16].copy_from_slice(&ev.id.to_le_bytes());
    b[16..20].copy_from_slice(&x.to_le_bytes());
    b[20..24].copy_from_slice(&y.to_le_bytes());
    b[24..28].copy_from_slice(&0f32.to_le_bytes());
    b[28..32].copy_from_slice(&0f32.to_le_bytes());
    b[32..36].copy_from_slice(&0f32.to_le_bytes());
    b.to_vec()
}

fn run(ip: &str, port: u16, connect_data: u32, key: [u8; 16], rx: Receiver<Cmd>) -> Result<()> {
    unsafe {
        tb_init();
    }
    let host = unsafe { tb_host_create(1, 48) };
    if host.is_null() {
        return Err(anyhow!("enet host create failed"));
    }
    let ip_c = std::ffi::CString::new(ip)?;
    let mut peer: *mut c_void = std::ptr::null_mut();
    let rc = unsafe { tb_connect(host, ip_c.as_ptr(), port, 48, connect_data, &mut peer) };
    if rc != 0 {
        return Err(anyhow!("enet connect rc={rc}"));
    }
    eprintln!("[ctl] connecting to {ip}:{port} (connect_data={connect_data:#x})");

    let mut crypt = Crypt { key, seq: 0 };
    let mut buf = vec![0u8; 65536];
    let mut ev = TbEvent { type_: 0, peer: std::ptr::null_mut(), channel: 0, len: 0 };
    let mut connected = false;
    let mut last_ping = Instant::now() - Duration::from_secs(1);

    loop {
        // 1) 处理 ENet 事件
        let got = unsafe { tb_service(host, 2, &mut ev, buf.as_mut_ptr(), buf.len() as c_int) };
        if got > 0 {
            match ev.type_ {
                1 => {
                    connected = true;
                    eprintln!("[ctl] enet connected");
                    for (ty, payload) in [(TYPE_START_A, vec![0u8, 0u8]), (TYPE_START_B, vec![0u8])] {
                        let pkt = crypt.seal(ty, &payload);
                        unsafe { tb_send(peer, CH_GENERIC, pkt.as_ptr(), pkt.len() as c_int, 1) };
                    }
                    unsafe { tb_flush(host) };
                }
                2 => {
                    eprintln!("[ctl] enet disconnected");
                    break;
                }
                3 => {
                    if ev.len >= 2 {
                        let pkt = &buf[..ev.len as usize];
                        let ty = u16::from_le_bytes([pkt[0], pkt[1]]);
                        if ty == 1 {
                            if let Some((inner, _payload)) = crypt.open(pkt) {
                                if inner == TYPE_TERMINATE {
                                    eprintln!("[ctl] server terminated stream");
                                    break;
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        // 2) 发周期 ping（100ms）
        if connected && last_ping.elapsed() >= Duration::from_millis(100) {
            last_ping = Instant::now();
            let payload = [4u32.to_le_bytes(), 0u32.to_le_bytes()].concat();
            let pkt = crypt.seal(TYPE_PING, &payload);
            unsafe { tb_send(peer, CH_GENERIC, pkt.as_ptr(), pkt.len() as c_int, 1) };
            unsafe { tb_flush(host) };
        }

        // 3) 处理本地命令（不阻塞）
        loop {
            match rx.recv_timeout(Duration::from_millis(0)) {
                Ok(Cmd::Touch(t)) => {
                    let payload = touch_payload(&t);
                    let pkt = crypt.seal(TYPE_INPUT, &payload);
                    // MOVE/HOVER 允许不可靠：服务端只做 digitizer 状态更新，丢一帧无影响。
                    let reliable = if matches!(t.kind, TouchKind::Move) { 0 } else { 1 };
                    unsafe { tb_send(peer, CH_TOUCH, pkt.as_ptr(), pkt.len() as c_int, reliable) };
                }
                Ok(Cmd::RequestIdr) => {
                    let pkt = crypt.seal(TYPE_IDR, &[0u8, 0u8]);
                    unsafe { tb_send(peer, 1, pkt.as_ptr(), pkt.len() as c_int, 1) };
                }
                Ok(Cmd::Shutdown) => {
                    unsafe { tb_destroy(host) };
                    return Ok(());
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    unsafe { tb_destroy(host) };
                    return Ok(());
                }
            }
        }
        unsafe { tb_flush(host) };
    }
    unsafe {
        let _ = tb_peer_state(peer);
        tb_destroy(host)
    };
    Ok(())
}

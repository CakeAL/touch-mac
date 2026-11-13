# bridge-rs — Rust 版触控/视频桥

把 iPad/安卓平板的触控与画面接到 Mac 原生链路的单二进制实现：

```
平板 App ──touch(47777)──┐
        └─video(47779)──┤   adb reverse
                         ▼
                    bridge-rs ──RTSP/ENet/GCM──► Sunshine ──► libvirtualhid ──► VoidLink ──► WindowServer
```

Sunshine 侧不改一个字节：仍用它的 `/launch`、RTSP 会话和 libvirtualhid 虚拟触控屏，
所以 SIP 保持开启、不需要任何受限 HID entitlement。

## 为什么不用 moonlight-common-c

原来的 `bridge/client` 用 LCC 只为了拿「控制流 + 视频流」，但我们需要把视频转发到平板、
还要按帧做关键帧请求。Rust 版直接实现了协议本身（RTSP 7 条请求、ENet 控制流、
AES-128-GCM 信封、Sunshine 私有视频切片），因此是一个无依赖的静态二进制。

## 模块

| 文件 | 职责 |
|---|---|
| `src/launch.rs` | HTTPS `/launch`（mTLS 客户端证书）、`/cancel`，解析 `<sessionUrl0>` |
| `src/rtsp.rs` | OPTIONS/DESCRIBE/SETUP(audio,video,control)/ANNOUNCE/PLAY，`build_sdp()` |
| `src/control.rs` | ENet 控制流（vendor enet + C shim）、GCM 封包、触摸报文、100ms ping、IDR 请求 |
| `src/video.rs` | 视频 UDP 收流：NV 头解析、FEC 校验片过滤、帧组装、SPS/PPS 提取、500ms ping |
| `src/relay.rs` | 视频 TCP 中转（给平板） |
| `src/touch.rs` | 触控 TCP 服务（给平板），握手时下发 `#aspect` |
| `vendor/enet*` | Moonlight fork 的 ENet（2.x sockaddr API）+ 极薄 C shim |

## 用法

```bash
cargo build --release
./target/release/touchbridge
```

参数（`--help` 可看全部）：`--host 127.0.0.1 --appid 881448767 --width 1920 --height 1080 --fps 60 --bitrate 20000`。

平板侧：

```bash
adb reverse tcp:47777 tcp:47777   # 触控
adb reverse tcp:47779 tcp:47779   # 视频
```

## 中转帧格式（与 `android-app` 的 VideoClient 对应）

```
u8 type | u32 BE len | payload
type=0x01 CONFIG: 整段 Annex-B（SPS+PPS，带起始码）
type=0x02 FRAME : u64 BE pts_us | u8 flags(bit0=key) | Annex-B AU
```

## 踩过的坑

- **证书必须是 X.509 v3**：LibreSSL 默认签 v1，rustls 直接拒绝
  （`UnsupportedCertVersion`），用 `-extfile` 带上 basicConstraints/keyUsage/EKU 重签。
- **build.rs 必须 `rerun-if-changed` 到 C 文件**：改了 shim 签名却只重编 Rust，
  会变成 6 参调 5 参函数，`tb_connect` 里写坏指针直接 SIGSEGV。
- **视频里混着 Reed-Solomon 校验片**：它们的 NV 头字段是乱码，不按
  `fecIdx >= dataShards` 过滤就会看到 `spi >> 8` 出现上万的假序号、帧永远拼不齐。
- **每个 IDR 都带 SPS/PPS，但不能每次都下发 CONFIG**：否则平板端解码器每 5 秒重建一次，永远停在「等待画面」。
- 客户端连上来后必须**主动请求一个 IDR**，否则只能等下一帧关键帧（默认 5s 一次兜底）。
- 会话必须有视频和音频两条流：服务端 10s 收不到对应 UDP ping 就整场结束（`stream_audio=false` 时音频 ping 也要发）。

## 实测（2026-11-13）

- 触控：平板点按 → `contact 1 presence: touching`，sender 随会话变化（如 `0x100070FCF`）。
- 视频：平板冷启动到首帧 **约 620 ms**（`CONFIG → codec started → first frame rendered`），1920×1080@60。
- 单会话 Sunshine CPU 约 4.5%，WindowServer 无明显增量。

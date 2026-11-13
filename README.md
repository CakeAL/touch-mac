# touch-mac —— 把安卓平板变成 Mac 的原生触控屏

只是一个实验性质的研究项目。

平板上显示 Mac 的画面，手指在平板上按下时 Mac 收到的是**真正的多点触控事件**（`BKDirectTouchState`，不是鼠标模拟）。画面走 adb（USB 线），触控从平板回灌到 Mac。

```
┌────────────── 平板 (Android) ──────────────┐        ┌──────────── Mac ─────────────┐
│  TouchBridge App                           │        │                              │
│   ├─ SurfaceView / MediaCodec  ← H.264/HEVC│◀──TCP──┤ 47779 视频+音频 (TCP)        │
│   ├─ TouchSurface  触控 → 行协议 ──────────┼──TCP──▶│ 47777 触控 (TCP)             │
│   └─ 设置面板 ─────────────────────────────┼──TCP──▶│ 47781 设置/控制 (TCP)        │
└────────────────────────────────────────────┘  adb   │                              │
                                                 reverse│ touchbridge (Rust)          │
                                                        │   ├─ HTTPS /launch  → Sunshine│
                                                        │   ├─ RTSP 握手              │
                                                        │   ├─ UDP 收视频/音频         │
                                                        │   └─ ENet 控制流 (加密)      │
                                                        │            │                 │
                                                        │   Sunshine.app (已签名)      │
                                                        │     └─ libvirtualhid         │
                                                        │          └─ IOHIDUserDevice  │
                                                        │               ↓ displayUUID  │
                                                        │   WindowServer → BKDirectTouchState
                                                        └──────────────────────────────┘
```

## 为什么必须这么绕

1. **自己造虚拟触屏没有权限。** macOS 27 起，用户态创建虚拟 HID 需要 `com.apple.developer.hid.virtual.device` entitlement；这个 entitlement 只有 Apple 签发的 Developer ID + 描述文件能拿到，自签会被内核直接 SIGKILL。
2. **物理 USB HID 触屏也不行。** 逆向结论（见 [analysis/root-cause.md](analysis/root-cause.md)）：WindowServer 判断「这个服务是不是某块屏的数字化仪」时，读的是 **HID 服务对象的顶层属性 `displayUUID`**。物理 HID 的 Event Service 顶层属性由内核驱动 `AppleUserHIDEventDriver` 在创建时就定死，白名单里没有 `displayUUID`；用户态注入只会落进 `HIDEventServiceProperties` 子字典 → 日志 `ignoring digitizer event ... from unsupported service`。
3. **唯一现成可用的注入通道，是本机已签名的 Sunshine（CanvasHost/Lumen）。** 它用 `IOHIDUserDeviceCreateWithProperties` 创建虚拟触屏，创建字典里直接带 `Product / VendorID / ProductID / ReportDescriptor / displayUUID / CGDirectDisplayID / DisplayIntegrated / DigitizerCollectionDispatch` —— 这八个键让它成为合法的数字化仪。我们不改它的二进制、不碰它的签名，只是**以 Moonlight 客户端的身份连上去**，让它在会话期间替我们创建那块虚拟触屏（`VoidLink HID Touchscreen`）。

所以本项目的定位是：**复用 Sunshine 的虚拟 HID，把它当作「屏幕 + 触控注入器」**，自己只负责画面中转、触控转发和参数控制。

## 快速开始

### 依赖

| 依赖 | 说明 |
| --- | --- |
| macOS 27+ | 需要 `__builtin_available(macOS 27.0)` 的虚拟触控路径 |
| [Sunshine.app](https://github.com/The-Fried-Fish/CanvasHost) | 提供 `/launch`、RTSP、libvirtualhid 编码/触控 |
| Rust（cargo 1.9x） | 编译 `bridge-rs` |
| Android SDK（`aapt2`/`d8`/`apksigner`/`adb`） | 编译平板 App，本机不需要 gradle、不需要 NDK |
| 平板 + USB 线 | adb 连接，`adb reverse` 承载全部数据 |

### 1. 编译

```bash
cd bridge-rs && cargo build --release && cd ..
android-app/build.sh          # 输出 android-app/build/touchbridge.apk
```

### 2. 配对（一次性）

Sunshine 的 HTTPS 对每个请求都校验客户端证书，必须让桥的证书出现在它的已配对列表里：

```bash
bridge-rs/pair.sh                                   # 写入 ~/.config/sunshine/sunshine_state.json
osascript -e 'quit app "Sunshine"'; sleep 2; open -a /Applications/Sunshine.app
```

> 官方配对流程要在 Web UI 上点 PIN，而那个密码在 state 里只有 sha256 哈希，无法反推。直接写 `named_devices` 是等价且唯一免 PIN 的做法。`bridge-rs/pair.sh --revert` 可撤销。

### 3. 安装 App

```bash
adb install -r android-app/build/touchbridge.apk
```

### 4. 启动

```bash
bridge-rs/run.sh setup    # adb reverse tcp:47777/47779/47781
bridge-rs/run.sh -d       # 后台常驻（日志 /tmp/touchbridge.log）
```

然后打开平板上的 **TouchBridge**。

桥是**按需会话**：平时只监听端口不碰 Sunshine；平板 App 连上 47777 才唤醒 Sunshine、跑 `/launch`、建 RTSP 会话；App 断开 3 秒后自动 `/cancel` 收尾，虚拟触屏随之消失（`hidutil list | grep -i voidlink` 会变空）。

## 传输层：为什么是 TCP over adb，能不能换

**adb 线上跑的不是 TCP/IP。** USB 这一段是 adbd 自己的协议（bulk 端点 + 固定头 + 载荷），`adb reverse tcp:47777` 只是「在设备侧监听一个 TCP socket、在主机侧也开一个 TCP socket、中间由 adbd 搬运字节」。所以「TCP 还是 UDP」只在两端 socket API 的层面成立。

| 方案 | 可用性 | 实测/预期 | 结论 |
| --- | --- | --- | --- |
| `adb reverse tcp:`（当前） | ✅ | 触控单向 0.15–0.78 ms；视频流 3.5 ms | 采用 |
| `adb reverse udp:` | ❌ adb 不支持（只有 `tcp:` / `localabstract:`） | — | 不可用 |
| USB 网络共享 + 直连 UDP | ✅ 平板开「USB 网络共享」后走 `rndis0` | 省掉 adbd 一层，理论再省 1–2 ms，但多一层 IP/NAT，且要自己处理丢包 | 可选实验 |
| `adb exec-out` 管道 | ✅ 仍是 adbd | 少一次 socket 转接，收益未测 | 可选实验 |
| libusb / AOA 裸 bulk | ✅ 但平板要进 accessory 模式 | 可控性最高，等于自己写 adb | 成本过高 |
| Wi-Fi UDP（不走线） | ✅ | ping `avg 36.7 ms / max 123.8 ms` | 比 USB 差，不采用 |

**为什么最后选 TCP：** 视频帧必须完整（少一个分片就是花屏/绿屏），TCP 的重传正好省掉这份麻烦；而且 adb 这一段本身已经是可靠传输，实测 3.5 ms 已经很低，换 UDP 收益有限、风险更大。

**另外，之前那 14 ms 的延迟不是 TCP 的锅。** adbd 对「只下行、没有上行流量」的 reverse socket 会攒包，小包要等十几毫秒才发；给视频 socket 每毫秒级写 1 个字节的心跳后，延迟从 `17.5 ms → 1.5 ms`。这条心跳就写在 `VideoClient` 里，间隔可用 `/data/local/tmp/tb_ka` 调（默认 2 ms）。

## 参数与设置

平板右上角 **⚙** 打开设置面板：

- **分辨率**只选档位：`1080p / 2K / 4K`。实际编码宽度由桥按**平板屏幕比例**自动算（例如 1080p + 2800×1752 的平板 → 1726×1080），所以画面原生就是平板比例，不需要拉伸，也不会有黑边。
- 帧率（30/60/90/120）、码率（10–80 Mbps）、HEVC、HDR/10-bit、串流音频。
- 客户端开关：**画面铺满平板**（关掉则按比例留边）、**显示左上角调试信息**、**显示触点圆圈**。

点「应用并重连」后桥会 `exec` 一个新进程重启会话（约 1 秒断线）。

设置也直接存在 `~/.config/touchbridge/settings`：

```ini
res=1080          # 档位高度：1080 / 1440 / 2160（也接受 1080p / 2k / 4k）
screen=2800x1752  # 平板屏幕像素；App 连上时会自动上报并覆盖
fps=60
bitrate=40000
hevc=1
hdr=0
audio=1
```

桥的命令行参数（都会覆盖文件）：`--res --width --height --fps --bitrate --hevc/--no-hevc --hdr/--no-hdr --audio/--no-audio`。其中 `--width/--height` 一般不用给，留空即按 `res × 屏幕比例` 自动算。

设置口协议（`127.0.0.1:47781`，行协议）：

```
get                → #cfg res=1080 screen=2800x1752 ... size=1726x1080
set fps=120        → #ok
apply              → #applied（桥保存设置并重启自己）
```

### 中转协议（App 侧）

`47777`（触控，纯文本行）：

| 行 | 含义 |
| --- | --- |
| `d/m/u <id> <x> <y>` | 按下/移动/抬起，坐标 0..1，原点左上 |
| `c` | 全部抬起 |
| `i` | 请求关键帧 |
| `p` | 时钟探测 → `#pong <us>` |
| `h` | 心跳 → `#hb <us>` |
| `s <w> <h>` | 上报平板屏幕像素，桥据此决定编码宽高 |
| — | 服务端下发 `#aspect <ratio>` 与 `#t0 <us>` |

`47779`（视频/音频，二进制）：`u8 type + u32 BE len + payload`，`type` 为 `0x01` 参数集（`u8 codec` + Annex-B SPS/PPS）、`0x02` 视频帧（`u64 BE pts | u8 flags | u64 BE send_us | AU`）、`0x03` 音频（`u64 pts | PCM s16le 48k 立体声`）、`0x04` 时钟 tick。

## 实测数据

端到端（单帧从桥发出 → 平板 `releaseOutputBuffer`），1920×1080：

| 段 | 耗时 | 说明 |
| --- | --- | --- |
| 桥内排队 | ~0.0 ms | 组帧后立即写 socket |
| adb reverse | 1.5–2.5 ms | 心跳 2 ms（`/data/local/tmp/tb_ka` 可调）；5 ms 时 3.5 ms，无心跳时 17.5 ms |
| 解码 + 合成 | 8.7–9.1 ms | 硬件解码 ~4 ms + 等 vsync 平均 ~4 ms |
| **合计** | **10–12 ms** | 状态行显示的数字 |

编解码对比（同机同链路，各 20 秒）：

| 编码 | 解码+合成 | 合计 |
| --- | --- | --- |
| **HEVC（8/10-bit）** | **8.9 ms** | **13 ms** |
| H.264 | 26.5 ms | 30 ms |

H.264 反而慢 3 倍：Sunshine 的 H.264 编码器带 B 帧/重排序窗口，解码器要多等一个 GOP 重排；HEVC 是低延迟无 B 帧。AV1 在 macOS 上没有编码器，不可用。

起播（首次连接）耗时：

| 阶段 | 耗时 | 说明 |
| --- | --- | --- |
| 平板连上 → 会话建立（/launch + RTSP + 首个 IDR） | ~1.1 s | 含 Sunshine 冷启动时更久（约 3–4 s） |
| 解码器启动 → 首帧上屏 | ~50 ms | 启动时立刻请求 IDR，并保留已排队的关键帧 |

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 画面整体变绿 | 解码队列溢出导致参考帧断裂（码率过高，adb 送不过来）。桥和平板都会立刻请求关键帧，通常 1 帧内恢复。仍频繁出现就把码率降到 40 Mbps 以下，或在设置里关掉 HDR/10-bit。 |
| 没有声音 | 三星的 `AudioHardening` 会把没有音频焦点的播放静音。App 已在 `onResume` 申请 `AUDIOFOCUS_GAIN`；仍无声先确认 Mac 上真的有声音在播（`stream_audio = true`，串流期间 Mac 本地扬声器会被静音，这是设计）。 |
| 连不上 / 一直 `connecting` | `adb reverse --list` 看三个端口是否还在；`bridge-rs/run.sh setup` 重建。 |
| 端口被占 | 历史上 7000 被 macOS ControlCenter（AirPlay 接收）占用，现已固定用 4777x。 |
| 会话中途自己结束 | 桥有 10 秒看门狗：Sunshine 的 video/audio/control 任一路 ping 超时就会收尾。看 `/tmp/touchbridge.log` 里的 `Ping Timeout`。 |
| 面板打不开 | 齿轮在右上角，点 `(2700, 100)` 附近。 |
| 刚连上要等好几秒才出画面 | 以前解码器启动会清空队列、只能等下一个 GOP（约 5 s）。现已在启动时保留排队中的 IDR 并立刻请求关键帧；若仍慢，看 `video feed #0` 与 `codec started` 的时间差。 |
| Sunshine 启动慢 | 它退出要等约 10 秒；`open -a` 期间重复启动无效，桥会自动重试 60 次。 |

## 已知边界

- **没有真 HDR。** 这份 Sunshine 在 macOS 上 `is_hdr()` 恒为 false、没有 HDR 元数据实现，`dynamicRangeMode=1` 只会回落到 SDR。能拿到的是 **HEVC Main10 10-bit SDR**；要真 HDR10 必须改 Sunshine 源码重编，而重编会丢掉虚拟 HID 的签名 → 得不偿失。
- **多点触控只到单指针。** WindowServer 侧确实收到多个 contact（`pathsSeen: 1 2`），但 App 层只收到鼠标事件，`NSTouch` 不投递。这条链在 macOS 上等价于单点触屏（tap-to-click）。
- 平板持续解码 + 显示，耗电和发热都高于本地使用。
- 会话期间必须有 USB 连接；Wi-Fi 延迟明显更差（未做优化）。

## 目录

```
bridge-rs/            Mac 侧桥（Rust 单二进制）
  src/launch.rs       HTTPS /launch、/cancel（客户端证书）
  src/rtsp.rs         OPTIONS/DESCRIBE/SETUP/ANNOUNCE/PLAY + SDP
  src/control.rs      ENet 控制流 + AES-128-GCM（触摸上报、IDR 请求、ping）
  src/video.rs        UDP 收流、RTP/NV 头解析、分片组帧、SPS/PPS 提取
  src/audio.rs        UDP 收 Opus → libopus 解码 → PCM
  src/relay.rs        把视频/音频转成 47779 上的帧流
  src/touch.rs        47777 行协议 → 触摸事件
  src/control_port.rs 47781 设置/控制口
  src/settings.rs     ~/.config/touchbridge/settings
  vendor/enet/        Moonlight fork 的 ENet（C，随二进制编译）
  certs/              客户端证书（配对用）
  pair.sh             写 Sunshine 已配对列表
  run.sh              setup / -d / 前台
android-app/          平板 App（纯 Java，手工 aapt2 + d8 打包）
  src/.../MainActivity.java   窗口、触控采集、活动框、时钟同步
  src/.../VideoClient.java    收流、MediaCodec 解码、AudioTrack 播放
  src/.../SettingsPanel.java  设置面板
  src/.../AudioPlayer.java    PCM 播放
  src/.../H264Sps.java        参数集解析（宽高修正）
  build.sh                    无 gradle 打包
analysis/             逆向与设计记录
  root-cause.md       为什么物理 USB HID 与自签虚拟 HID 都不可行（含地址级证据）
  native-touch-bridge.md  桥接链路设计、延时拆解、踩坑记录
probe/                当初取证用的小工具（属性注入、feature flag、类转储…），仅供参考
tools/cache_stubs.py  共享缓存 stub → 导入符号解析
Handoff.md            研究过程交接记录（历史，不代表当前实现）
```

## 踩过的坑（写下来免得重犯）

1. **adb reverse 攒包** —— 只下行的小包会等十几毫秒，必须定期写心跳（已内置）。
2. **cargo 不会因为改了 C 文件就重编 cc 产物** —— `build.rs` 忘了 `rerun-if-changed` 时，改了 shim 签名会直接 SIGSEGV。
3. **libvirtualhid 的客户端证书要 X.509 v3** —— LibreSSL 默认签出来是 v1，rustls 直接拒。
4. **`encoderCscMode=2` 会让画面偏绿** —— 这份 Sunshine 的 10-bit 路径下取 Rec.709 有问题，用 0（Rec.601）正常。
5. **安卓 `MediaCodec` 解 Opus 会抛 `Invalid to call at Released state`** —— 改为 Mac 侧 libopus 解码、传 PCM。
6. **主线程不能写 socket** —— `NetworkOnMainThreadException`，改队列 + 独立发送线程。
7. **`adb shell am start` 不会重启已有进程** —— 改完 UI 要 `am force-stop` 再启动。

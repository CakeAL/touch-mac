# 用 Sunshine 的 VoidLink 虚拟触控屏给 Mac 注入原生触控（桥接链）

日期：2026-11-13　环境：macOS 27.3 (26C5035r)，SIP enabled，arm64，主显示器 DM72u displayID=3，
UUID `8BF51424-0C57-4680-A7F9-9092F20311B9`。

本文记录“平板触控 → Mac 端桥接客户端 → Sunshine → libvirtualhid → WindowServer 原生
digitizer”这条链的实测结果。所有结论标注 VERIFIED / INFERRED / UNVERIFIED。

---

## 0. 结论速览

1. VERIFIED：桥接客户端只需完成一次标准 Moonlight 会话（`/launch` + RTSP + video/audio/control），
   Sunshine 就会在**会话生命周期内**创建 `VoidLink HID Touchscreen`（VendorID `0x1209`，
   ProductID `0x4c53`，Transport `Virtual`，usage page `0xD` usage `0x4`）。
2. VERIFIED：这个虚拟服务对象的**顶层属性** `displayUUID` 就是主显示器 UUID。
   用 `IOHIDServiceClientCopyProperty(service, "displayUUID")` 直接读到
   `8BF51424-0C57-4680-A7F9-9092F20311B9` —— 与 Samsung 物理触控屏读回 `NULL` 形成决定性对比。
3. VERIFIED：WindowServer 随即打印 `digitizer attached`，并为它建立
   `BKDirectTouchState ... touchScreen; accessory; builtIn: NO; displayIntegrated: YES;
   authenticated: NO; displayUUID: <主显示器>`，随后逐接触点打印
   `contact N presence: touching / none`。这就是物理 USB 触控屏始终拿不到的对象。
4. VERIFIED：应用层收到的是**指针事件**（mouseMoved / mouseDown / mouseDragged / mouseUp），
   坐标映射正确（归一化 → 显示器像素 → AppKit 坐标，y 轴翻转）。
5. VERIFIED：双指会生成两个独立 contact（`pathsSeen: 1 2`，`down: 2 / up: 2`），
   但应用层仍然只有**一个指针**；未观察到 NSTouch 多点投递（见 §5）。
6. VERIFIED：会话必须“有视频”才能存活（服务端 video/audio 线程各自 10s ping 超时，
   客户端 LCC 10s 无视频包即 `ML_ERROR_NO_VIDEO_TRAFFIC`），但**不需要解码**。

---

## 1. 链路与角色

```
平板触摸 (adb getevent / 未来 App)
        │  bridge/tablet_touch.py  (EV_ABS 多指协议 → 归一化坐标)
        ▼
bridge/client  ── SS_TOUCH_PACKET(0x55000002) ──► Sunshine (control stream UDP 47999)
                                                      │ AUTH/解密后 input::passthrough
                                                      ▼
                                          input.cpp: mac_native_touch=true 分支
                                                      │ native_touch.cpp:97 字节 HID 报文
                                                      ▼
                                     IOHIDUserDeviceHandleReportWithTimeStamp
                                                      ▼
                              VoidLink HID Touchscreen（会话期间存在）
                                                      ▼
                    WindowServer: BKIOHIDService(displayUUID) → BKDirectTouchState
                                                      ▼
                                            应用层指针事件
```

关键点：**虚拟设备的属性来自创建字典**（`IOHIDUserDeviceCreateWithProperties`），
所以 `displayUUID` 天然是服务顶层属性；物理 USB 的 `AppleUserHIDEventService` 由内核驱动另建，
未知键只能落进 `HIDEventServiceProperties` 子字典（见 `analysis/root-cause.md`）。

---

## 2. 复现步骤（本机已验证）

前置：Sunshine 已把 `bridge/certs/client.crt` 写入
`~/.config/sunshine/sunshine_state.json` 的 `named_devices`（`bridge/add_client_identity.sh`，
会先备份为 `sunshine_state.json.bak.bridge`），并重启 Sunshine。

```bash
# 1) 交互式会话：内部完成 cancel → /launch → client --stdin + 平板转发
cd /Users/cakeal/vsc/touch-mac
bridge/session.sh --rotate 0            # 平板竖屏；横屏用 --rotate 90/270
# 无平板时可用 --no-tablet，然后手动写 FIFO：
#   printf 'd 1 0.5 0.5\n' > /tmp/touchpipe
#   printf 'm 1 0.6 0.5\n' > /tmp/touchpipe
#   printf 'u 1 0.6 0.5\n' > /tmp/touchpipe
```

`Desktop` 的 appid 是 **881448767**（`/applist` 实测，不是 1）。

观测：

```bash
hidutil list | grep -i voidlink
# 0x1209 0x4c53 ... Virtual AppleUserHIDEventService VoidLink HID Touchscreen
probe/svcprop VoidLink          # displayUUID 有值
log stream --predicate 'process == "WindowServer" AND eventMessage CONTAINS "TouchEvents"'
grep -E "begin touch packet|Dropping malformed|verify tag" ~/.config/sunshine/sunshine.log
```

---

## 3. 实测证据（2026-11-13 18:39–18:47）

- 设备出现（hidutil）：`0x1209 0x4c53 0x0 13 4 0x100066072 Virtual AppleUserHIDEventService
  VoidLink HID Touchscreen AppleUserHIDEventDriver`，同批 `IOHIDUserDevice 0x10006606f`。
- 服务属性（`probe/svcprop VoidLink`，走 `IOHIDServiceClientCopyProperty`，与
  `-[BKIOHIDService propertyForKey:]` 同链路）：
  `displayUUID = 8BF51424-0C57-4680-A7F9-9092F20311B9`，`DisplayIntegrated = true`，
  `DigitizerCollectionDispatch = true`，`Built-In = <NULL>`，`Transport = Virtual`。
- WindowServer（PID 11082）：
  - `Services added: [<BKIOHIDService: ...; eventSource: externalAccessory; primaryUsagePage: 0xD;
    primaryUsage: 0x4; name: VoidLink HID Touchscreen; transport: Virtual; displayUUID: 8BF5...>]`
  - `digitizer attached (sender 100066072) service:<... serviceStatus: matched>`
  - `init: <BKDirectTouchState: ...; touchScreen; accessory; builtIn: NO; displayIntegrated: YES;
    authenticated: NO; displayUUID: 8BF5...; contacts: []; destinations: []>`
  - `[100066E32] contact 1 presence: touching` / `contact 2 presence: touching`
  - `touchstats ... down: 2, up: 2, rangeIn: 2, rangeOut: 2, pathsSeen: 1 2,
    destinations: { targetID ...: { touchIDs: EE0-EE1 } }, averageProcessingTime (µs): 2202`
- 会话结束时：`digitizer detached (sender ...) builtIn:0`、
  `cancel -- digitizer did disappear:<BKDirectTouchState ... contacts: []>` —— 设备与状态随会话销毁。

---

## 4. 延迟实测

| 区段 | 实测 | 依据 |
|---|---|---|
| client `LiSendTouchEvent` → WindowServer contact | ≈ 1 ms | client ts `…782.212932` 对应 contact `18:46:22.208470` |
| WindowServer contact → 应用 mouseDown（点按） | 到手指抬起才下发（tap-to-click 语义） | 按下 1.6 s 再抬起：contact `22.208` 出现，mouseDown 在 `22.951`（抬手 `23.823` 前约 0.87 s） |
| adb `getevent` 转发一段 | 未测（需真机手指） | — |

结论（INFERRED）：注入链路本身亚毫秒级；用户感知延迟主要来自 adb 转发与“抬手才点击”的语义，
而不是 Sunshine/HID。

---

## 5. 语义边界（重要）

- **单指**：可靠。10 次点按 → 10 次 mouseDown/mouseUp，坐标精确
  （触摸 `(0.30,0.30)` → `(576,756)`，即 1920×1080 窗口的 AppKit 坐标）。
- **拖动**：按住移动时指针跟随（mouseDragged），符合“触屏当鼠标”的预期。
- **双指**：WindowServer 收到 2 个 contact，但应用层只有 1 个指针；
  仅捕获到 `NSEventTypeGesture`(29)/`subtype 63`（touch 事件）且 `touchesMatchingPhase` 为 0，
  **没有** `touchesBegan/Moved/Ended` 的多点投递，也没有 magnify/rotate/scroll。
  ⇒ 该路径在 macOS 上等价于“单点触屏”，不能给应用真正的多点手势。
- `BKDirectTouchState` 的 `authenticated: NO` 是外部 HID digitizer 的常态；
  本机未找到把它变成 `YES` 的非签名手段（UNVERIFIED：该位是否影响多点投递）。

---

## 6. 客户端实现要点（踩坑记录）

- `SERVER_INFORMATION.serverCodecModeSupport` 必须非 0，否则 `LiStartConnection` 直接返回 -1
  （`Connection.c` 断言）。本客户端填 `SCM_H264`。
- `LiInitializeConnectionContext` 不存在；回调结构体是
  `LiInitializeConnectionCallbacks / VideoCallbacks / AudioCallbacks / ServerInformation`。
- 视频/音频回调可传 NULL（LCC 用 fake 回调丢帧），但**必须收视频包**，否则 10 s 后断开。
- `/launch` 不带 `corever` 才拿到明文 `rtsp://`（带 `corever=1` 得 `rtspenc://`）。
- 首次触摸可能撞上 `native_touch::connect` 的 `ready()` 轮询（100×10 ms + 150 ms），
  最坏约 1.15 s 后设备才可用；早到的事件会被丢弃（Sunshine 会回退 CGEvent workaround）。
- 触摸包：`uint32 size(BE)=32` + `uint32 magic(LE)=0x55000002` + `eventType` + `zero[1]` +
  `rotation(LE)` + `pointerId(LE)` + 5 个 little-endian float（x, y, pressure, areaMajor, areaMinor），
  共 36 字节。

---

## 7. 平板 App 路径（无 root，推荐）

`android-app/` 是一个不依赖 gradle 的最小 APK（`aapt2` + `javac` + `d8` + `apksigner` 手工打包）：

```text
平板 TouchBridge App (MotionEvent)
    ↓ TCP 127.0.0.1:47777  （adb reverse tcp:47777 tcp:47777）
Mac bridge/touchd.py            文本行协议 d/m/u/c
    ↓ FIFO /tmp/touchpipe
bridge/client (moonlight-common-c)
    ↓ SS_TOUCH_PACKET → control stream (UDP 47999)
Sunshine → libvirtualhid → VoidLink HID Touchscreen
    ↓
WindowServer: BKDirectTouchState → contacts → 应用指针事件
```

- 选 47777 而不是 7000：macOS 的 ControlCenter 占着 TCP 7000（AirPlay 接收），
  `adb reverse` 会把平板连接打到 ControlCenter 上。
- 平板 App 的 socket 写必须在独立线程：`onTouchEvent` 在主线程，
  直接写 socket 会抛 `NetworkOnMainThreadException`（第一版实现踩过，表现为
  “连上即断 + write failed”）。
- 坐标（曾出错，已修正）：协议 y 的原点是**左上角**，Sunshine 直接写入 HID digitizer，
  WindowServer 再转成 AppKit 的左下原点（实测 `AppKit.y = (1 - y) * H`）。第一版多翻了
  一次 y，导致“平板顶部 → Mac 底部”上下颠倒；实测 `input tap 1400 200`（平板顶部）
  在颠倒版本里落在 `loc=123.5`，修正后为 `loc=1003.5`。
- 活动框：`session.sh` 用 `system_profiler SPDisplaysDataType` 的 `UI Looks like: 1920 x 1080`
  得到 Mac 主显示器比例，`touchd.py` 在连接建立时下发 `#aspect 1.777778`；App 据此在
  屏幕上画居中的 16:9 框，**框外触摸不转发**、框内坐标线性映射到 Mac 全屏，两者比例
  不同时也不会拉歪；要换比例用 `session.sh --aspect 16:10`。
- 修正后的四角实测（2800×1752 画布，活动框 2800×1575，上下各留 88.5 px）：
  `tap 1400 200 → loc=960,1003.5`、`tap 1400 1600 → loc=960,43.5`、
  `tap 200 800 → loc=137,592`、`tap 2600 800 → loc=1783,592`；`tap 1400 30`
  （框外）完全不产生指针事件。

已用 `adb shell input tap/swipe` 端到端验证（不经人手）：
`touchd` 统计 `d=3 m=118 u=3`，应用收到 3 组 MOUSEDOWN→MOUSEDRAG→MOUSEUP，
坐标与预期完全一致；双指注入时 WindowServer 记录 `contact 1` 与 `contact 2`
同时 `presence: touching`。

## 8. 尚未完成

- 真机手指在本 App 上的验收（需有人在平板上触摸；`adb shell input` 已覆盖等价链路）。
- 平板侧视频：本方案里会话被 Mac 端桥接占用，平板看不到 Mac 画面；
  若要“平板显示 + 触控”，需改用带触摸转发的客户端（改 Moonlight Android 客户端，服务端不动）。
- **多点语义分歧（UNVERIFIED）**：本机实测 WindowServer 收到 2 个 contact、
  但 `touchwatch`（`acceptsTouchEvents=YES`、`allowedTouchTypes` 含 Direct）
  只在 `NSEventTypeGesture`(subtype 63) 里拿到 0 个 touch，应用层只有单指针。
  用户表示此前用“Moonlight 多点触控版”在平板上验证过多点触控，二者矛盾，
  需按当时的客户端版本/App 复测后才能定论。

## 9. Rust 版桥（`bridge-rs`，已完成，取代 `bridge/client`）

`bridge/client` 用 moonlight-common-c 只能“发触控 + 丢帧”，要做到“平板看画面 + 触控”，
必须拿到原始 H.264 帧并按需请求关键帧。Rust 版直接实现协议本身，单二进制无外部依赖。

### 9.1 链路与端口

```
平板 App ─touch(47777)─┐
        └─video(47779)─┤ adb reverse
                       ▼
bridge-rs ─RTSP/ENet/GCM─► Sunshine ─► libvirtualhid ─► VoidLink ─► WindowServer
```

Sunshine 的二进制与签名均未改动（`codesign --verify --deep --strict` 通过），
只读它的 `/launch`、RTSP 与控制流。

### 9.2 实现要点（协议细节见 `bridge-rs/README.md`）

- `launch.rs` HTTPS `/launch`（mTLS，X.509 v3 客户端证书）→ `rtsp://` 会话 URL（`corever=0` 走明文 RTSP）。
- `rtsp.rs` 七条请求：OPTIONS → DESCRIBE → SETUP audio/video/control → ANNOUNCE → PLAY。
  ANNOUNCE 的 SDP 必须带全 `x-nv-*`/`x-ss-*` 属性，且**每条属性行尾多一个空格**，否则 400。
- `control.rs` ENet（vendor enet 2.x + C shim）+ AES-128-GCM 信封
  （`u16 0x0001 | u16 len | u32 seq | 16B tag | ct`，IV=`seq LE4|0*6|'C'|'C'`）。
- `video.rs` 收 Sunshine 私有切片：`12B RTP | 4B 保留 | 16B NV 头 | payload`；
  按 `SOF/EOF` 组帧、丢 `fecIdx >= dataShards` 的 RS 校验片、剥 8B（`0x01`）或 44B（`0x81`）帧头、
  提取 SPS/PPS 作为 CONFIG。
- `relay.rs` 给平板的中转格式：`u8 type | u32 BE len | payload`，
  CONFIG=Annex-B 参数集，FRAME=`u64 BE pts | u8 flags | AU`。

### 9.3 实测（VERIFIED，2026-11-13 19:37–19:44）

- 触控：平板点按 → `[100070FCF] contact 1 presence: touching / none`，
  `BKDirectTouchState ... displayUUID: 8BF51424-...` 正常。
- 视频：平板冷启动首帧 **≈620 ms**（`video CONFIG 33 bytes` → `codec started` →
  `first frame rendered (1920x1080)`），截图可见 Mac 桌面实时画面。
- 会话中每 5 s 请求一次 IDR 兜底；新客户端连入立即请求 IDR。

### 9.4 三个必须知道的坑

1. **证书版本**：LibreSSL 默认签 X.509 v1，rustls 报 `UnsupportedCertVersion`；
   用 `-extfile` 加 basicConstraints/keyUsage/EKU 重签成 v3。
2. **build.rs 的 `rerun-if-changed`**：改了 C shim 签名但只重编 Rust，
   会变成“6 参调 5 参函数”，`tb_connect` 写坏指针直接 SIGSEGV。
3. **CONFIG 去重**：每个 IDR 都带 SPS/PPS，若每次都下发 CONFIG，
   平板端解码器每 5 秒重建一次，画面永远停在「等待画面…」。

## 10. 延时与颜色（2026-11-13 20:1x）

- 平板 `WindowManager.LayoutParams.preferredDisplayModeId` 选 120 Hz（`Display.Mode 1 @ 120.00001Hz`），
  并给 `Surface` 设 `setFrameRate(120f, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)`。
  **实测状态行延时从 42 ms 降到 13–14 ms**（之前 SurfaceFlinger 按 60 Hz 合成，每帧白等一个 vsync）。
- 颜色：`x-nv-video[0].encoderCscMode=2` 会让平板解出整体偏绿的画面（实测截图全绿）；
  改回 `0`（Rec.601 limited）后颜色正常。可用 `CSC=2` 环境变量复现。
- 桥的重启（设置界面 `apply`）会断开触控连接：App 的读线程原来只在写失败时才重连，
  现在读线程 EOF 时主动 `closeQuietly()`，写线程随即退出并 400 ms 后重连 → 自动恢复会话。

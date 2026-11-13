# mac-app —— macOS 本机预览客户端

不接平板，直接在 Mac 上开一个置顶悬浮小窗，显示 `bridge-rs` 转出的本机画面；鼠标按下 / 拖动 / 抬起按**单点触控**发给桥（`d/m/u 0 x y`）。用来在没有平板时验证「画面 + 触控注入」整条链路，也可以当随身取色/取点的小工具。

```
┌────────────── macOS ───────────────┐
│  TouchBridgeViewer.app (Swift)     │
│   ├─ VideoClient ← 47779 视频/音频 │
│   ├─ TouchClient ─→ 47777 触控     │
│   └─ 悬浮窗：aspect-fit + 触点 HUD │
└────────────────────────────────────┘
```

## 组成

| 文件 | 职责 |
| --- | --- |
| `Sources/TouchBridgeViewer/main.swift` | `NSApplication` 启动；`setActivationPolicy(.accessory)`（无 Dock 图标、不抢前台） |
| `Sources/TouchBridgeViewer/AppDelegate.swift` | 开窗、关窗退出、失活时补发抬起 |
| `Sources/TouchBridgeViewer/ViewerWindowController.swift` | 860×540 的 `NSPanel`；置顶、非激活；状态栏 0.25s 刷新；鼠标→触控换算；触点看门狗；自检 |
| `Sources/TouchBridgeViewer/VideoView.swift` | 画面视图：`CALayer.contents = CVImageBuffer`，aspect-fit letterbox；鼠标事件归一化；HUD（状态胶囊、底部提示、触点圆圈） |
| `Sources/TouchBridgeViewer/TouchClient.swift` | TCP 47777：`d/m/u/c/i/h`、`#aspect` 解析、断线重连、1s 心跳 |
| `Sources/TouchBridgeViewer/VideoClient.swift` | TCP 47779：拆帧、VideoToolbox 硬解、丢帧恢复、fps/延迟统计 |
| `Sources/TouchBridgeViewer/AnnexB.swift` | Annex-B 起始码拆分、NAL 类型、转 AVCC |
| `Sources/TouchBridgeViewer/VideoFormat.swift` | SPS/PPS → `CMVideoFormatDescription`；AU → `CMSampleBuffer`（非关键帧标记 `NotSync`） |
| `tools/decodecheck.swift` | 离线解码抓包的工具（见文末） |

## 构建与运行

```bash
cd mac-app
./build.sh        # swift build -c release + 组装 build/TouchBridgeViewer.app + ad-hoc 签名
open build/TouchBridgeViewer.app
```

也可以绕过 LaunchServices 直接跑二进制（更彻底地不抢焦点）：

```bash
./build/TouchBridgeViewer.app/Contents/MacOS/TouchBridgeViewer
```

前置条件：

- `bridge-rs` 正在运行，`127.0.0.1:47777`（触控）与 `127.0.0.1:47779`（视频）可连；
- Sunshine 可用（桥会在触控连接出现时 `/launch`）。

**会话由触控连接触发**：只连 47779 不会唤醒 Sunshine。`TouchClient` 连上 47777 后桥才开始会话，视频客户端随之收到参数集和关键帧。断开触控后桥有 3 秒重连窗口，之后 `/cancel`。

## 交互

- 窗口可缩放、置顶悬浮；`NSPanel` + `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`，点击画面**不会**把本 App 切到前台，也不抢键盘焦点。
- 画面内按下 → `d 0 x y`，拖动 → `m 0 x y`，抬起 → `u 0 x y`；坐标按实际显示区域（letterbox 内）归一化，原点左上，与 `android-app` 一致。
- 框外按下无效；拖出画面会 clamp 到边缘；抬起、关窗、以及「物理按键已松开但 mouseUp 丢了」都会补发释放（0.25s 看门狗）。
- HUD 显示：分辨率、fps、延迟、解码状态、触控连接状态、当前触点；底部有操作提示。

## 协议对齐

触控 `47777`（文本行）：

| 行 | 含义 |
| --- | --- |
| `d/m/u 0 x y` | 按下 / 移动 / 抬起，坐标 0..1，原点左上 |
| `c` | 全部抬起 |
| `i` | 请求关键帧（IDR） |
| `h` | 心跳 → `#hb <us>` |
| — | 服务端连上即下发 `#aspect <ratio>`、`#t0 <us>` |

视频 `47779`（二进制，`u8 type + u32 BE len + payload`）：

| type | 内容 |
| --- | --- |
| `0x01` | `u8 codec`（0=H.264，1=HEVC）+ Annex-B SPS/PPS；参数变化时才下发 |
| `0x02` | `u64 BE pts_us`、`u8 flags`（bit0=key）、`u64 BE send_us`、AU（Annex-B） |
| `0x03` | 音频（本客户端忽略）；`0x04` 时钟 tick（用于估算时钟偏差） |

解码：VideoToolbox 硬解，`kCVPixelFormatType_32BGRA` + IOSurface，`RealTime`；非关键帧设置 `kCMSampleAttachmentKey_NotSync`（否则 VT 会把 P 帧当同步帧、参考帧队列被重置 → `-12909`）；积压或解码失败时丢掉到下一个关键帧，并以 0.5s 去抖请求 IDR。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TOUCHBRIDGE_HOST` | `127.0.0.1` | 桥地址 |
| `TOUCHBRIDGE_TOUCH_PORT` | `47777` | 触控端口 |
| `TOUCHBRIDGE_VIDEO_PORT` | `47779` | 视频端口 |
| `TOUCHBRIDGE_SELFTEST` | 未设置 | `=1` 时启动 2s 后向自己的窗口投递一次「按下→拖动→抬起」，打印 `[selftest]` 与 `[touch] ->` 日志；配合 mock 端口可验证坐标换算，不会真的点到桌面 |

## 已知限制与排错

- 需要 macOS 14+；仅 HEVC/H.264 8-bit；不播放音频；链路本身只有单指针，所以只模拟一根手指（id 0）。
- 窗口一直显示「等待画面」：先看桥日志（`[video] frame #...`）确认有帧；确认 47777 的连接在（这是会话触发条件）。如果桥的上一场会话卡住，重启桥 / Sunshine 即可。
- 偶发 `解码错误 -12909`：桥侧 UDP 重组偶尔产出损坏的 AU（抓包见 `logs/stream.bin` 分析），VT 比 ffmpeg 严格；客户端会丢弃并等下一个 IDR，通常一瞬间恢复。频繁出现就降低码率或改用 H.264。
- 首次用 Finder 打开可能被 Gatekeeper 拦（ad-hoc 签名）：用 `open` / 命令行启动，或在「系统设置 → 隐私与安全性」里放行。
- `.accessory` 模式没有 Dock 图标，关窗即退出；从终端后台起时日志无缓冲，便于 `tail -f`：

```bash
nohup build/TouchBridgeViewer.app/Contents/MacOS/TouchBridgeViewer > logs/viewer.log 2>&1 &
```

## 离线解码工具

`tools/decodecheck.swift` 用与客户端相同的封装逐帧喂给 VideoToolbox，排查「码流问题还是客户端问题」：

```bash
cd mac-app
CLANG_MODULE_CACHE_PATH=$PWD/.cache/clang SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang \
  swiftc -O tools/decodecheck.swift \
    Sources/TouchBridgeViewer/AnnexB.swift Sources/TouchBridgeViewer/VideoFormat.swift \
    -o /tmp/decodecheck
/tmp/decodecheck logs/stream.bin    # 用 python 抓 47779 原始字节写入该文件
```

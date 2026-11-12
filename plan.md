# 平板当触控屏：macOS 27.2 实施方案

目标：安卓平板通过 USB / WiFi 连 Mac，平板镜像 Mac 屏幕，**Mac 把这块屏当成触控显示器**（系统触控 UI 生效：红绿灯放大、菜单加高、下拉刷新），手指 / 笔直接操作。最低 macOS 27.2。

---

## 1. 状态与结论（2026-11-12）

| 项 | 状态 |
| --- | --- |
| root 安卓 + USB HID gadget | ✅ 已实测：Mac 端 `touchCaps = 1` |
| 软件虚拟触屏（用户态 SPI） | ❌ 27.2 内核拒绝，root 也不行 |
| 多点触摸 | ⏳ 单指已通，16 指描述符待验证 |
| 视频链路 | ⏳ 未开始 |
| S Pen | ⏳ 未开始 |

**结论：走真 USB HID 设备。** Mac 侧不需要任何注入代码——系统把它当硬件触屏，直接进入 27 的原生触控管线。

## 2. 为什么不是软件方案

在本机 27.2.1 实测，`IOHIDUserDeviceCreateWithProperties`（CanvasHost 用的那个 SPI）被内核拒绝：

```
(IOHIDFamily) IOHIDResourceDeviceUserClient:0x0 <proc> is not entitled
[com.apple.iohid:userdevice] IOServiceOpen:0xe00002c2   ← kIOReturnBadArgument
```

排除过程：最小合法描述符、只传 `ReportDescriptor`、9 个属性全传、0–255 全部 options、沙盒 + `com.apple.security.device.hid`、开发者证书签名、LaunchServices 启动、root —— 一律 "not entitled"。

真 USB 设备不经过 `IOHIDResourceDeviceUserClient`，因此不受该限制。这也是为什么 27.2 上硬件路线反而更稳。

## 3. 架构

```
┌──────────────── Android ────────────────┐        ┌──────────── macOS 27.2 ─────────────┐
│  MediaCodec 解码 → SurfaceView          │  视频  │  ScreenCaptureKit 捕获               │
│         ▲                               │◄───────┼── VideoToolbox 编码                  │
│  MotionEvent / S Pen                    │        │                                      │
│         └── 写 /dev/hidg0（HID report）  │  触摸  │  IOHIDFamily 解析 → WindowServer      │
│                     │                   │───────►│  → AppKit 手势识别器 → 前台 App       │
└─────────────────────┼───────────────────┘  USB   └──────────────────────────────────────┘
                      └── USB gadget（HID 触屏）
```

- 触摸走 USB gadget，Mac 看到的是标准 HID Touch Screen。
- 视频走 WiFi（USB 口被 gadget 占用），后续可尝试 `adb` + `hid` 双功能共存。

## 4. 已验证：单指 HID gadget

[android/hid_gadget.sh](android/hid_gadget.sh) 用 configfs 建一个 HID gadget：

- 描述符：Digitizer `0x0D` / Touch Screen `0x04`，Finger 集合（Tip Switch `0x42`、In Range `0x32`、Contact ID `0x51`、X/Y 16 位 `0x30/0x31`），逻辑范围 `0..0xFFFF`
- 报告：6 字节 = flags(1) + contact id(1) + x(2) + y(2)，小端
- 用法：`check` 体检 → `setup` 建 gadget → `tap` 在屏幕中央点一下 → `rollback` 还原

实测结果：设备插入后 `NSScreen.touchCapabilities` 从 0 变成 1，Mac 认为这块屏可触控。

## 5. 待做：16 指多点

单指描述符只能验证“被识别为触控屏”。多点需要换成 16 个 finger collection + Contact Count：

```
header:  05 0D 09 04 A1 01
finger ×16:
         05 0D 09 22 A1 02
         09 42 09 32 09 47            // Tip Switch / In Range / Confidence
         15 00 25 01 75 01 95 03 81 02
         75 05 95 01 81 03             // 5 bit padding
         09 51 25 7F 75 08 95 01 81 02 // Contact ID
         05 01 09 30 09 31 27 FF FF 00 00 75 10 95 02 81 02  // X/Y
         C0
end:     05 0D 09 54 15 00 25 10 75 08 95 01 81 02 C0   // Contact Count = 16
```

报告：每指 6 字节（flags / id / x / y）+ 1 字节计数 = 97 字节。

状态位：`0x07` = touching（tip + in-range + confidence），`0x04` = 抬起（只留 confidence），抬起那帧仍带 id，发完再释放槽位。

Android 侧：`MotionEvent` 的 `pointerId` 映射到槽位 1..16，`ACTION_MOVE` 更新坐标，`ACTION_UP` 发抬起帧，`ACTION_CANCEL` 全部抬起。

## 6. 视频链路

- Mac：`SCStream`（ScreenCaptureKit）→ `VTCompressionSession`（HEVC，`EnableLowLatencyRateControl`）→ 长度前缀 NAL → TCP
- 平板：`MediaCodec` 硬件解码 → `SurfaceView`
- 参数：`RealTime=true`、`AllowFrameReordering=false`、8–20 Mbps、关键帧 1s
- 链路：WiFi 5GHz 优先；若后续能做到 `adb` + `hid` 共存，可改走 `adb reverse`

## 7. 坐标映射

- 平板按内容区（去掉黑边）归一化到 `0..65535`
- 旋转在平板侧先转成横屏坐标再发
- 镜像时按 Mac 主屏的宽高比 letterbox，坐标只覆盖内容区
- HiDPI 不影响归一化坐标

## 8. 分阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P0 ✅ | 单指 gadget | `touchCaps = 1` |
| P1 | 16 指描述符 + Android 触摸转发 | TouchLab 日志出现 `[touch]`；双指缩放/滚动；红绿灯放大 |
| P2 | 视频链路 | 1080p60，端到端 < 60ms |
| P3 | S Pen | 压感/倾斜/悬停/笔键 |
| P4 | WiFi、码率自适应、音频、剪贴板 | — |

## 9. 风险

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 内核没编 `CONFIG_USB_CONFIGFS_F_HID` | gadget 建不起来 | 换内核 / 上 ESP32-S3 HID 桥 |
| USB 口只支持 host | 平板当不了设备 | 同上 |
| SELinux 拦 `/dev/hidg0` | 写报告失败 | `setenforce 0` 或 Magisk policy |
| 切 gadget 后 USB adb 断开 | 失去控制 | 先开无线 adb；保留 `rollback` |
| 多指描述符被系统拒 | 只能单指 | 退回单指 + 手势合成（CGEvent） |
| 延迟不达标 | 手感差 | 硬编、零拷贝、视频走 5GHz |

## 10. 附录：27.2 的软件路径（已封，留档）

CanvasHost 的 `native_touch.cpp` 展示了 27.0/27.1 上的做法，27.2 已不可用：

```c
IOHIDUserDeviceCreateWithProperties(alloc, props, 0);
// props: ReportDescriptor / displayUUID / CGDirectDisplayID /
//        DisplayIntegrated / DigitizerCollectionDispatch / VendorID / ProductID / Product / Transport
IOHIDUserDeviceCopyService(dev);   // 等 AppleUserHIDEventService
IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report, len);
```

[mac/touchbridge.m](mac/touchbridge.m) 是这套调用的重写版，保留作参考；若未来系统放开或拿到 entitlement，可直接切回。

## 11. 仓库结构

```
touch-mac/
├── README.md
├── plan.md
├── android/hid_gadget.sh
├── mac/
│   ├── touchbridge.m            # 软件虚拟触屏（27.2 不可用）
│   └── TouchLab/                # 验证 App
├── probe/                       # screeninfo / vnat / vkeyb / vtouch / vtcreate
└── tools/                       # send_touch.py / demo_tap.py
```

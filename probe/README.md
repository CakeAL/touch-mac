# 探针与结论：macOS 27.2 的触控接口

环境：macOS 27.2.1 (26B131)，arm64，Xcode 27 SDK（`MacOSX27.2.sdk`）。
结论时间：2026-11-12。

## 1. 核心结论

| 结论 | 证据 |
| --- | --- |
| 真 USB HID 触屏 → 系统认作触控屏 | 安卓 root + HID gadget 插入后 `touchCaps = 1` |
| 用户态软件造虚拟触屏 → 27.2 拒绝 | 内核日志 `IOHIDResourceDeviceUserClient: <proc> is not entitled` |
| root 也不能绕过 | `sudo` 运行同样失败，日志同样是 "not entitled" |
| 不是 TCC 问题 | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` 返回 granted |
| 不是描述符/属性问题 | 最小 vendor 描述符、9 个属性全传，均失败 |
| 公开 entitlement 无效 | 沙盒 + `com.apple.security.device.hid`、开发者证书签名，均失败 |

`IOHIDUserDeviceCreateWithProperties` 的错误链：

```
IOHIDUserDeviceCreateWithProperties(alloc, props, opts)   → NULL
  → IOServiceOpen(IOHIDResource)                          → 0xe00002c2 (kIOReturnBadArgument)
  → kernel: IOHIDResourceDeviceUserClient: <proc> is not entitled
```

## 2. 27 原生触控的公开事实

| 事实 | 出处 |
| --- | --- |
| `NSScreen.touchCapabilities`（27.0+），无触屏 = 0 | `AppKit.framework/Headers/NSScreen.h:75` |
| Sidecar 触摸只能从 `NSGestureRecognizer` 收到，不走 responder chain / 事件监听 / `sendEvent:` | Apple TN3212 |
| 非触控原生框架由 AppKit 做鼠标模拟；`NSIsTouchNative` 可关闭 | TN3212 + Info.plist 文档 |
| `NSGestureRecognizer.allowedTouchTypes` 27 起默认 Direct | `NSGestureRecognizer.h:95` |
| 27 新增触控滚动 API | `NSScrollView.h:137-151` |

数据链路（从符号与字符串推断）：

```
HID digitizer (DisplayIntegrated)
  → BackBoard  BKHIDDirectTouchEventProcessor / BKDirectTouchState
  → WindowServer (SkyLight)  kSLSHIDEventTypeDirectTouch
  → AppKit  __NSSidecarTouchFilterCGEvent / __NSSenderIsSidecar
  → NSEventTypeDirectTouch → NSGestureRecognizer
```

## 3. 隐藏接口清单

### 3.1 公开但不在主文档
- `NSIsTouchNative`（Info.plist，Bool）：声明 App 自己处理触摸，关掉鼠标模拟。
- `NSViewGestureRecognizerIsExclusive`（Info.plist）。
- `NSScreen.touchCapabilities` / `NSScreenTouchCapabilitiesMultiTouch`。
- `NSEventSidecarTouchesEnabled`：AppKit 内部开关。
- `SupportExternalTouchscreen`：backboardd 里的第三方触屏开关字符串。

### 3.2 SPI / 私有
- SkyLight：`_kSLSHIDEventTypeDirectTouch`、`_SLSSidecarGestureEventsSupported`、
  `_SLSDisplayStreamSidecarTouchBar`、`__XSetSidecarTouchEnabled`、
  `WSHIDSenderIsSidecarDigitizer(BKHIDEventSenderInfo*)`、`WSTouchCursorState*`、
  `SLSGetDisplaysWithUUID` / `SLSCopyDisplayUUID`。
- BackBoard：`BKHIDDirectTouchEventProcessor`、`BKDirectTouchState`（`displayIntegrated` / `authenticated` / `senderID`）、
  `BKSHIDEventCopyDisplayIDFromDigitizerEvent`、`BKSHIDEventSetDigitizerInfo*`；
  私有 entitlement：`_BKPersistentPropertyDigitizerAccessEntitlement`、`_BKCancelTouchesEntitlement`。
- CoreDisplay：显示信息键 `DisplaySupportsTouch`；`CDVirtualDisplayCreate/ApplySettings`。
- IOKit：`IOHIDUserDeviceCreateWithProperties`、`IOHIDUserDeviceHandleReportWithTimeStamp`、
  `IOHIDEventCreateDigitizerFingerEvent(WithQuality)`、`IOHIDEventSystemClientDispatchEvent`、
  `kIOHIDDisplayIntegratedKey`（"DisplayIntegrated"）。

## 4. 工具

| 文件 | 作用 |
| --- | --- |
| `screeninfo.m` | 打印显示器 UUID / builtin / `touchCapabilities` |
| `vnat.m` | 按 CanvasHost 的 SPI 序列创建虚拟触屏（预期失败，复现 entitlement 墙） |
| `vkeyb.m` | 用同一 SPI 造虚拟键盘（证明是整类被拒，不是触屏特有） |
| `vtouch.m` | 旧的 `IOHIDUserDeviceCreate` 尝试 |
| `vtcreate.m` | 属性组合遍历 |
| `touch-check.c` | 读 Samsung Event Service 及父链属性（Direct vs Search） |
| `svcprop.c` | 用 BackBoard 同款 `IOHIDServiceClientCopyProperty` 读服务属性表 |
| `ffprobe.c` | 查询 `_os_feature_enabled_impl` 开关 |
| `hidclass.m` / `hidproto.m` | 运行时枚举 HID.framework 的私有类/方法/协议 |

编译：`./build.sh` → `probe/build/`。

## 5. 对硬件路线的意义

真 USB 设备不经过 `IOHIDResourceDeviceUserClient`，所以：

- 不需要任何 entitlement，不需要 root（Mac 侧）；
- 系统直接走 27 的 digitizer → WindowServer 管线；
- 平板端只需要一个标准 HID Touch Screen 描述符。

已实测：安卓 root + configfs HID gadget → `touchCaps = 1`。见仓库根目录 [plan.md](../plan.md) 与 [android/hid_gadget.sh](../android/hid_gadget.sh)。

## 6. 2026-11-13 修正：USB 直连也不需要 entitlement，但**过不了 displayUUID 判定**

上面的结论只对了一半：USB 直连确实不需要 entitlement 就能被 HID 系统识别、被解析成 digitizer 事件，
但 WindowServer 还需要该服务对象**自身的顶层属性 `displayUUID`**，而它只能在对象创建字典里出现。

实测（`./svcprop SAMSUNG`）：

```text
displayUUID                  <NULL>      ← 缺这个，事件被丢
DisplayIntegrated            true
DigitizerCollectionDispatch  true
Built-In                     <NULL>
Transport                    "USB"
```

完整根因见 [analysis/root-cause.md](../analysis/root-cause.md)。

# Handoff — macOS 原生多点触控屏研究

**项目名称：** Android USB HID Gadget → macOS Native Direct Touch  
**交接日期：** 2026-11-13  
**接手 Agent：** OpenCode  
**项目阶段：** 根因已闭环（`displayUUID` 顶层属性必须在对象创建时给出）；免授权物理直连路线判定不可行，转入架构决策  
**优先级：** DriverKit dext 可行性验证（见 §13）

---

## 0. 给 OpenCode 的执行指令

你现在接手一个已经进行多轮实验的 macOS HID / WindowServer 逆向工程项目。

**不要从头开始，也不要重复已经验证失败的方案。**

首要任务是阅读本交接文档，检查现有实验源码，并从 Apple IOHIDFamily、DriverKit、SkyLight / BackBoard 的服务注册机制入手，找到无需 Apple 受限虚拟 HID entitlement 的原生多点触控实现路径。

要求：

1. 优先使用可运行的最小 C / Objective-C / Swift 实验验证推断。
2. 所有结论标注 `VERIFIED`、`INFERRED` 或 `UNVERIFIED`。
3. 保持 SIP 开启，不将降低系统安全级别作为默认解决方案。
4. 不接受 CGEvent 鼠标模拟、Trackpad 手势模拟作为最终方案。
5. 不接受 Sunshine / Moonlight 视频串流作为最终输入链路。
6. 每次实验记录 RegistryID、API 返回值、属性直接读回、WindowServer 日志与原生触控验收结果。
7. 如有更可行的无授权架构，可以改变实现路径，但必须保留 USB 直连和 WindowServer 原生多点触控语义。

## 1. 最终目标与约束

### 目标

使用已 Root 的三星 Android 平板，通过 USB 连接 Mac，作为 macOS 原生多点触控屏。

目标事件路径：

```text
Android touchscreen
    ↓
Android kernel / userspace
    ↓
USB HID Gadget
    ↓
macOS physical USB HID stack
    ↓
IOHIDEventSystem
    ↓
WindowServer / BackBoard
    ↓
BKDirectTouchState
    ↓
Native multitouch interaction
```

允许替换中间某些组件，但要求最终仍是原生 Digitizer / Direct Touch，不是指针模拟。

### 硬件与系统

**Mac：**
- MacBook Pro，Apple M1 Pro
- macOS 27.3 beta（用户报告的版本）
- SIP 必须保持开启
- 无付费 Apple Developer 账户及相关受限授权

**Android：**
- Samsung Galaxy Tab S7+
- Root
- One UI 8.5（用户报告）
- 能控制 USB HID Gadget 配置
- 当前 HID Gadget 节点：`hid.usb0`
- 当前 USB 描述为 `SAMSUNG_Android`
- USB VID `0x04e8`，PID `0x6860`

**连接方式：**
- USB
- 不使用网络视频串流
- 不使用蓝牙

### 完成条件

必须看到 Samsung 对应 SenderID 被 WindowServer 接受，并创建 `BKDirectTouchState`；进一步验证多个触点可以进入系统 Direct Touch 路径。

仅看到 HID Report、`DisplayIntegrated = 1` 或 `NSScreen.touchCapabilities = 1`，不算成功。

---

## 2. 当前最重要的结论

### VERIFIED — HID 数据链路正常

Android 已经可以通过 USB HID Gadget 发送：

- Digitizer Usage Page：`0x0D`
- Touchscreen Usage：`0x04`
- 最多 16 个触点
- 97 字节 Input Report
- 触点坐标、Touch、Range 等字段

macOS 已经识别并解析为 `Digitizer` 事件。

WindowServer 日志包含：

```text
EventType: Digitizer
DisplayIntegrated: 1
TransducerType: Hand
X: 0.395477
Y: ...
SenderID: 0x10004BF39
```

因此不要把主要精力重新投入 HID Report Descriptor 或 USB 传输。

### VERIFIED — WindowServer 拒绝 Samsung 服务

典型日志：

```text
[com.apple.SkyLight:default]
handle_digitizer_added:
digitizer service has no usable displayUUID property;
treating as no digitizer added
```

以及：

```text
[com.apple.BackBoard:TouchEvents]
ignoring digitizer event for display <main>
from unsupported service:

senderID: 0x10004BF39
eventSource: externalAccessory
primaryUsagePage: 0xD
primaryUsage: 0x4
name: SAMSUNG_Android
transport: USB
serviceStatus: matched
```

说明设备被 HID 系统识别，事件到达 WindowServer，但未获得 Direct Touch 支持。

### VERIFIED — 存在成功的原生触控对照组

Sunshine / VoidLink 创建的虚拟 HID Touchscreen 可以成功激活 macOS 的 `BKDirectTouchState`。

成功注册日志曾包含：

```text
handle_digitizer_added: digitizer added for display

digitizer attached

BKDirectTouchState:
  touchScreen
  accessory
  builtIn: NO
  displayIntegrated: YES
  authenticated: NO
  displayUUID:
    8BF51424-0C57-4680-A7F9-9092F20311B9
```

注意：`authenticated: NO` 不等于虚拟 HID 创建不需要 entitlement。

这个对照组很重要：它证明当前系统确实具有接受非内建 Direct Touch 设备的运行时能力。

### 2A. displayUUID 闭环（2026-11-13 定稿）

完整根因报告见 [`analysis/root-cause.md`](analysis/root-cause.md)。以下为结论，全部有源码或反汇编直接证据。

**结论 1（VERIFIED）— WindowServer 只认“服务对象自身的顶层属性 `displayUUID`”。**

- SkyLight `WS::Displays::WSHIDDisplayEventListener::hid_event_callback` @ `0x182b2c7d4`，digitizer 分支校验 `IOHIDEventGetType==1`、字段 `0x10000==0xff15`、`0x10001==3`、`0x10002==8`，随后 `IOHIDServiceClientCopyProperty(service, CFSTR("displayUUID"))`（CFString `0x1e225ddf0`，11 字符）+ `CFUUIDCreateFromString`
- BackBoard `-[BKHIDDirectTouchEventProcessor _handleDirectTouchEvent:service:]` @ `0x264114728`：`displayUUID` 为空且服务非内建 → 打印 “unsupported service”（日志点 `0x264114b34`）并丢弃
- `-[BKIOHIDService propertyForKey:]` @ `0x1dd2b92c4` → `IOHIDServiceClientCopyProperty(serviceRef, key)`；`displayUUID` 存 ivar `+0x78`，由 `_setUpInitialProperties` @ `0x1dd2b81bc` 填充
- `IOHIDServiceClientCopyProperty` @ `0x184ec50a0` 经 `IOHIDEventSystemClientCopyPropertyForService` @ `0x184ec5374` → `io_hideventsystem_copy_property_for_service` **走服务端属性表，不沿 IORegistry 父链搜索**。这就是“父链能搜到、API 返回 NULL”的原因

**结论 2（VERIFIED）— 顶层属性只能在对象创建字典里出现。**

- `IOHIDFamily/IOHIDEventService.cpp:191-193`：`IOHIDEventService::init(properties)` 仅 `return super::init(properties)`（`IOService`），创建字典整体成为顶层注册表属性
- 虚拟侧（Sunshine `libvirtualhid`）：`platf::macos::native_touch_t::connect` @ `0x1001dfce0` 用 `CFDictionaryCreate`（`0x1001e0068`）一次性给齐 `Product` / `VendorID=0x1209` / `ProductID=0x4c53` / `ReportDescriptor` / `Transport="Virtual"` / **`displayUUID`** / `CGDirectDisplayID` / `DisplayIntegrated` / `DigitizerCollectionDispatch`，再调 `IOHIDUserDeviceCreateWithProperties`（`0x1001e0084`）。**此后不再写任何属性**
- 而 `IOHIDUserDevice` 本身就是 `IOHIDEventService` → 属性与对象同源

**结论 3（VERIFIED）— 物理 USB 侧的创建字典由内核驱动生成，白名单不含 `displayUUID`。**

- `IOHIDFamily/AppleUserHIDEventService.cpp:757-812` `setSystemProperties` 只把固定 `propKeys[]`（SurfaceDimensions / SensorPropertySupported / KeyboardEnabled* / ReportInterval / SupportsGlobeKey / GameController* / PointerAccelerationType / ScrollAccelerationType / DigitizerGestureCharacterState / SupportsInk / SupportedEventMask / SupportedKeyboardUsagePairs / SupportedVendorUsagePairs）提升为顶层
- `:806` 注释原文 `// Publish remaining properties under "HIDEventServiceProperties" key` → 其余全部进入子字典，BackBoard 不读子字典
- HID 内核栈根本不认识 `displayUUID`（`grep -ri uuid tools/IOHIDFamily` 为空）；实测 `hidutil property --matching '{"Product":"SAMSUNG_Android"}' --get displayUUID` → `(null)`
- **决定性实测**（`probe/svcprop.c`，与 BackBoard 同款 API `IOHIDServiceClientCopyProperty`）：Samsung 服务返回 `Product=SAMSUNG_Android`、`Transport=USB`、`PrimaryUsagePage=13`、`PrimaryUsage=4`、`DisplayIntegrated=true`、`DigitizerCollectionDispatch=true`、`Built-In=<NULL>`、**`displayUUID=<NULL>`**。除 `displayUUID` 外别的输入全都就位

**结论 4（VERIFIED）— 无授权时没有任何用户态写入点。**

- `IOHIDFamily/IOHIDResourceUserClient.cpp:120-150` `IOHIDResourceDeviceUserClient::initWithTask`：先查 `com.apple.hid.manager.user-access-device`（命中则 `_privileged=true`），否则查 `com.apple.developer.hid.virtual.device`（`:33`）；都不命中则 `HIDServiceLogError("%s is not entitled", name)`
- `HID/PrivateHeaders/HIDVirtualEventService.h:165` 原文：使用虚拟事件服务接口必须持有 `com.apple.private.hid.client.event-dispatch`
- 自签带假 entitlement 的进程会被 `SIGKILL`（实测 exit 137）；未签名则 `IOHIDUserDeviceCreateWithProperties` 返回 `0x0`

**结论 5（INFERRED，证据强）— Apple 官方外部触屏开关在 macOS 上是死路。**

- `backboardd/SupportExternalTouchscreen` 默认 0，只影响 `_queue_displayUUIDForDigitizerService:` @ `0x264113954` 的回退值 `self+0xd8`（`chamoisDisplayUUID`）
- 全系统无 `setChamoisDisplayUUID:` 调用者：`BackBoardHIDTouchEventProcessor` 内该字符串仅 2 次（方法名 + 其 block 符号）、`chamoisDisplayUUID` 3 次；`BackBoardHIDEventFoundation` / `BackBoardServices` / `SkyLight` 均为 0；且无 `_objc_msgSend$setChamoisDisplayUUID:` 桩 → ivar 永不被赋值

**结论 6 — `_queue_addDigitizerStateForService:` 的 `<main>` 是回退显示名，不代表匹配成功。**

日志中的 `display <main>` 来自 `displayUUID` 为空时回退 `BKSDisplayUUIDMainKey`，属于日志噪音，不是接受成功的证据。

---

## 3. Samsung 的 IOKit Provider 链

已验证的完整链路：

```text
IOUSBHostDevice
  SAMSUNG_Android
  RegistryID: 0x10004bf28

  └── IOUSBHostInterface
      HID Interface
      RegistryID: 0x10004bf2e

      └── AppleUserHIDDevice
          AppleUserUSBHostHIDDevice
          RegistryID: 0x10004bf31

          └── IOHIDInterface
              RegistryID: 0x10004bf38

              └── AppleUserHIDEventService
                  AppleUserHIDEventDriver
                  RegistryID: 0x10004bf39
```

以上 ID 是某次实验的现场 ID，**断开重连后可能变化，不能在新程序中永久硬编码**。

设备匹配应使用：

```text
Product = SAMSUNG_Android
PrimaryUsagePage = 13
PrimaryUsage = 4
VendorID = 0x04e8
ProductID = 0x6860
```

`hidutil` 检查命令：

```bash
hidutil list --matching \
'{"PrimaryUsagePage":13,"PrimaryUsage":4}'
```

---

## 4. VoidLink 成功对照组

### 4.1 虚拟 HID 链路

```text
IOHIDUserDevice
  Product: VoidLink HID Touchscreen
  Transport: Virtual
  VendorID: 0x1209
  ProductID: 0x4c53

  └── IOHIDInterface
      └── AppleUserHIDEventService
          AppleUserHIDEventDriver
```

两个设备的 Event Service 使用相同的 Apple 系统驱动及通用匹配 personality。

### 4.2 关键上游属性

从 VoidLink `IOHIDUserDevice` 直接读取：

```text
CGDirectDisplayID = 3

displayUUID =
8BF51424-0C57-4680-A7F9-9092F20311B9

DigitizerCollectionDispatch = True
DisplayIntegrated = True
HIDVirtualDevice = True
DeviceOpenedByEventSystem = True
HIDDefaultBehavior = True
Privileged = False

PrimaryUsagePage = 13
PrimaryUsage = 4
MaxInputReportSize = 97
ReportInterval = 8000
```

其中：

```text
CGMainDisplayID() = 3
```

主显示器：

```text
DM72u
Display ID = 3
```

### 4.3 Sunshine 中的符号

执行：

```bash
strings -a \
"/Applications/Sunshine.app/Contents/MacOS/Sunshine" |
grep -iE \
'displayUUID|IOMFBUUID|CGDisplay|IOHIDUserDevice|DisplayIntegrated'
```

找到：

```text
IOHIDUserDeviceCreateWithProperties
IOHIDUserDeviceCopyService
CGDisplayCreateUUIDFromDisplayID
displayUUID
DisplayIntegrated
IOHIDUserDeviceHandleReportWithTimeStamp
```

**INFERRED：** Sunshine 很可能通过 `CGDisplayCreateUUIDFromDisplayID` 获取显示器 UUID，然后将其放入 `IOHIDUserDeviceCreateWithProperties` 的属性字典。

尚未通过调用点反汇编证实完整顺序。

---

## 5. 已完成的属性注入实验

### 5.1 成功：写入物理 AppleUserHIDDevice

使用：

```c
IORegistryEntrySetCFProperty(
    service,
    CFSTR("displayUUID"),
    CFSTR("8BF51424-0C57-4680-A7F9-9092F20311B9")
);
```

另设置：

```text
CGDirectDisplayID = CFNumber(3)
DigitizerCollectionDispatch = CFBoolean(true)
```

向：

```text
AppleUserHIDDevice
RegistryID: 0x10004bf31
```

写入后：

```text
set result = 0x00000000
```

三个属性都能通过 `IORegistryEntryCreateCFProperty` 直接读取。

**VERIFIED：** 物理 USB HID Device 层支持本次运行时属性写入。

这不等于 WindowServer 自动接受属性。

### 5.2 失败：向 AppleUserHIDEventService 直接写入

测试目标：

```c
io_service_t device = byID(0x10004bf39ULL);
io_service_t event  = byID(0x10004bf39ULL);
```

返回：

```text
displayUUID:
  set result: 0x00000000
  direct readback: NULL
  parent search: UUID

CGDirectDisplayID:
  set result: 0x00000000
  direct readback: NULL
  parent search: 3

DigitizerCollectionDispatch:
  set result: 0x00000000
  direct readback: NULL
  parent search: true
```

**VERIFIED：** 对 Event Service 调用 `SetCFProperty` 返回成功，但这些属性没有进入其直接 IORegistry 属性表。

根据 Apple 文档，`IORegistryEntrySetCFProperty` 将请求交给对象解释，不保证保存到属性表。

不要再重复该相同实验。

### 5.3 三层直接属性读回结果

| 属性 | AppleUserHIDDevice | IOHIDInterface | Event Service |
|---|---|---|---|
| `displayUUID` | 有 | 无 | 无 |
| `CGDirectDisplayID` | 有 | 无 | 无 |
| `DigitizerCollectionDispatch` | 有 | 无 | 无 |
| `DisplayIntegrated` | 无 | 无 | 有 |

`IORegistryEntrySearchCFProperty` 从 Event Service 通过父节点可以找到前面三个属性。

但 `IOHIDServiceClientCopyProperty` 对 Event Service 查询：

```text
displayUUID = NULL
DisplayUUID = NULL
CGDirectDisplayID = 未作为成功结果证实
```

成功的 VoidLink Event Service 用相同 API 查询 `displayUUID` 也为 NULL。

**重要：不能由此推断 WindowServer 一定沿 Provider 链查找 UUID。**

### 5.4 尚未验证：IOHIDInterface 直接写入

目标：

```text
RegistryID: 0x10004bf38
Class: IOHIDInterface
```

需要分别测试写入 API 返回值、直接属性读回、是否触发服务状态变化。

如果可写但不触发注册，应停止重复运行时注入，转向首次注册时机研究。

---

## 6. 失败或无效的研究方向

### 6.1 HID Event Service 的运行时属性设置

多次实验已说明：

- `IOHIDServiceClientSetProperty`
- `IOHIDDeviceSetProperty`
- `hidutil` 属性修改
- `IORegistryEntrySetCFProperty` 作用于 Event Service

都没有证明能够使 Samsung 获得原生 Direct Touch。

其中 `IORegistryEntrySetCFProperty` 返回 0 不代表直接属性写入成功。

### 6.2 仅靠修改 HID 描述符

目前 HID Report 被正确解析，Device 和 Event Service 均为 Touchscreen Usage。

因此不能把“换一个 HID 描述符”当作优先解决方案。

如果继续研究描述符，只应针对能够解释 WindowServer 接受条件的差异进行受控比较。

### 6.3 `ioreg -a -r -c AppleUserHIDDevice`

在当前环境中，这个查询曾返回 0 字节：

```text
/tmp/samsung-hid.plist = 0 bytes
```

`plistlib.InvalidFileException` 只是空输出的结果，不代表设备消失。

设备事实上能通过 `hidutil` 与完整 IOService 树确认存在。

推荐使用 IOKit C API 遍历实际 Provider 链，不再依赖该无输出的查询。

### 6.4 USB HID 与虚拟 HID 的 entitlement

**不要混淆：**

- 使用系统内置驱动识别物理 USB HID。
- 应用创建 `IOHIDUserDevice` 虚拟设备。
- 第三方提供 DriverKit HID Event Service。

三者权限路径不同。

Apple 对虚拟 HID 创建和部分 DriverKit 服务提供受限 entitlement。

不能假设 `sudo`、自签名 entitlement、伪造 plist 就能跳过 AMFI / DriverKit 校验。

---

## 7. 尚需研究的三个关键假设

### H1：注册时机问题

**INFERRED**

WindowServer 可能只在 HID Service 首次加入时读取显示关联信息。

Samsung 在 Device 创建并注册完成后才注入 UUID，可能已经太晚。

验证方案：

1. 找到物理 USB HID 初始化期间能够合并 Provider 属性的机制。
2. 在 Event Service 启动或向 WindowServer 注册前提供 `displayUUID`。
3. 对照首次注册日志，确认是否创建 `BKDirectTouchState`。

挑战：

- 拔插 USB 会销毁旧的 Registry 节点及运行时属性。
- 需要研究启动前属性合并，而不是“拔插之后马上写入”的竞争条件。
- `IOProviderMergeProperties` 存在于 DriverKit 匹配配置中，但并未证明可以无授权注入此 HID 场景。

### H2：WindowServer 使用额外的接受条件

**UNVERIFIED**

两组服务在以下字段有所不同：

```text
Samsung:
  Transport = USB
  Provider = AppleUserHIDDevice
  eventSource = externalAccessory

VoidLink:
  Transport = Virtual
  Provider = IOHIDUserDevice
  Event System 已接受并绑定显示器
```

需研究 WindowServer `handle_digitizer_added` 和 BackBoard `unsupported service` 的判定逻辑。

可能检查内容：

- 显示器 UUID 有效性
- Event Service 的属性访问路径
- Service 注册时间
- Transport / Provider 来源
- `DigitizerCollectionDispatch`
- 用户态 / 系统进程注册权限
- 其他服务状态与显示器关联条件

不能预设任意一项就是决定性原因。

### H3：通过 Virtual HID Event Service API 创建触控服务

**UNVERIFIED — 探索性分支**

历史 IOHIDFamily 源码中存在 Virtual Service 相关机制：

```text
_IOHIDServiceCreateVirtual
_IOHIDEventSystemAddService
```

此外，先前研究提出调查：

```text
IOHIDVirtualServiceClientCreateWithCallbacks
```

但尚未确认这个符号在当前 macOS 27.3 beta 中存在、能由普通进程调用、无需受限 entitlement，或能够成功加入系统级 Event System。

**不要将旧版 IOHIDEventSystem 测试服务器与现代 WindowServer 使用的系统级 HID Event System 混为一谈。**

验证顺序：

1. `dlsym` 检查导出符号。
2. 确认 API 参数、回调契约和运行层级。
3. 确认非特权进程能否创建服务。
4. 确认新服务能否被系统枚举。
5. 确认 WindowServer 是否识别。
6. 最后才接入 Samsung 多点触控数据。

若仅能创建进程私有 Event System，则该路线不满足目标。

---

## 8. 建议 OpenCode 的具体执行顺序

### P0：盘点现有源码与基线

检查项目目录中是否已有：

```text
touch-check.c
touch-inject.c
hid-touch-compare.c
check-hid-symbols.swift
Android HID Gadget scripts
HID Report Descriptor
WindowServer logs
```

优先复用现有代码。

记录：

```text
macOS build
SIP status
CGMainDisplayID
display UUID
Samsung RegistryID
VoidLink RegistryID
HID usage
Service driver
```

不要无故修改现有 Android Gadget。

### P1：完成 IOHIDInterface 写入实验

目标：

```text
IOHIDInterface
RegistryID: 0x10004bf38
```

写入三个候选属性，检查：

- 返回值
- 立即直接读回
- `touch-check` 读回
- `IOHIDServiceClientCopyProperty` 的差异
- WindowServer 是否重新注册服务

这是已有研究中尚未收敛的小实验。

### P2：分析 WindowServer 注册判定

重点字符串：

```text
handle_digitizer_added
digitizer service has no usable displayUUID property
unsupported service
BKDirectTouchState
BKIOHIDService
DigitizerCollectionDispatch
```

重点二进制与组件：

```text
WindowServer
SkyLight.framework
BackBoard 相关组件
IOHIDFamily
AppleUserHIDDrivers.dext
```

先确定具体框架路径、加载镜像与符号归属，不要假定所有逻辑都在 WindowServer 主可执行文件中。

比较 Samsung 和 VoidLink 首次服务加入的调用路径及属性来源。

产出：精确描述哪个方法读取 `displayUUID`、从哪个对象读取，以及什么条件使服务成为支持的 Touchscreen。

### P3：分析 HID Event Driver 初始化属性来源

已观察到：

```text
AppleUserHIDEventDriver
AppleUserHIDEventService
IOHIDInterface
```

在之前的反汇编中，`AppleUserHIDEventDriver::Start_Impl` 涉及 Provider 属性访问。

这些历史反汇编结论尚需复核。

产出：

- 初始化期间复制哪些 Provider 属性
- 是否会复制 `displayUUID`
- 是否存在设备匹配字典或属性合并入口
- 能否在 SIP 开启的情况下使用

### P4：虚拟服务 API 探针

仅作独立研究分支：

```text
IOHIDVirtualServiceClientCreateWithCallbacks
_IOHIDServiceCreateVirtual
_IOHIDEventSystemAddService
```

先做只读符号检查，再进行最小空服务注册实验。

必须单独记录：

```text
Symbol exported?
Client creation works?
Service visible in system HID Event System?
Requires entitlement?
WindowServer sees service?
Native touch accepted?
```

如果无法注入系统级服务，及时结束该路线。

### P5：最小端到端 PoC

只有确认服务可被 WindowServer 接受后，才将 Android 实际触点接入。

PoC 最低要求：

- 单指触摸和移动
- 触摸释放
- 两指独立追踪
- 正确归一化坐标
- 触摸状态和触点 ID 稳定
- WindowServer 不再出现 Samsung 对应的 `unsupported service`

随后扩展至 16 触点。

---

## 9. 推荐的验证命令

### 查看 Digitizer 设备

```bash
hidutil list --matching \
'{"PrimaryUsagePage":13,"PrimaryUsage":4}'
```

### 查看 USB Provider 链

```bash
ioreg -p IOService -w0 |
grep -B 18 -A 8 'SAMSUNG_Android'
```

### 查看实时 WindowServer 注册日志

```bash
log stream --style compact --level debug \
--predicate 'process == "WindowServer" AND
(eventMessage CONTAINS[c] "digitizer" OR
 eventMessage CONTAINS[c] "displayUUID" OR
 eventMessage CONTAINS[c] "SAMSUNG" OR
 eventMessage CONTAINS[c] "BKDirectTouchState")'
```

注意：触摸事件日志可能包含大量重复输出，建议通过 SenderID、时间戳和注册信息进行过滤。

### 原生触控验收

失败日志：

```text
ignoring digitizer event
from unsupported service
senderID: Samsung sender ID
```

成功所需证据：

```text
digitizer attached
BKDirectTouchState
senderID: Samsung sender ID
displayUUID: target display UUID
```

加上真实触控交互测试。

---

## 10. 公开资料与源码入口

### Apple API

- [IORegistryEntrySetCFProperty](https://developer.apple.com/documentation/iokit/1514882-ioregistryentrysetcfproperty)
- [IORegistryEntrySearchCFProperty](https://developer.apple.com/documentation/iokit/1514537-ioregistryentrysearchcfproperty)
- [IORegistryEntryCreateCFProperty](https://developer.apple.com/documentation/iokit/1514293-ioregistryentrycreatecfproperty/)
- [IOHIDUserDeviceCreateWithProperties](https://developer.apple.com/documentation/iokit/3334952-iohiduserdevicecreatewithpropert)
- [Virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)
- [DriverKit Family virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.virtual.device)
- [DriverKit HID Event Service entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.eventservice)

### 源码与研究参考

- [Apple IOHIDFamily](https://github.com/apple-oss-distributions/IOHIDFamily)
- [历史 IOHIDEventSystemMonitor.c，包含 Virtual Service 示例](https://github.com/aosm/IOHIDFamily/blob/master/tools/IOHIDEventSystemMonitor.c)
- [公开的 IOHIDEventSystemClient.h 镜像](https://github.com/guoxuzan/IOKit/blob/master/IOKit/Headers/hidsystem/IOHIDEventSystemClient.h)
- [Virtual HID entitlement 限制的实践记录](https://github.com/tkubicz/steam-controller-bridge/blob/main/docs/VIRTUAL_HID.md)

注意：历史 Apple Open Source 代码可能与 macOS 27.3 beta 不一致，不能直接据此断言私有 API 可用。

---

## 11. 最终交付要求

OpenCode 应输出：

1. **根因分析**：WindowServer 为什么接受 VoidLink 却拒绝 Samsung。→ 已完成，见 §2A 与 `analysis/root-cause.md`
2. **代码级证据**：尽可能提供函数、符号、调用位置、属性查找路径。→ 已完成（地址表见 `analysis/root-cause.md` 附录）
3. **权限矩阵**：明确哪些操作可在 SIP 开启、无受限 entitlement 下完成。→ 已完成，见 `analysis/root-cause.md` §5
4. **最小可运行 PoC**：尽可能完成原生触控注册，不接受鼠标事件模拟替代。→ **未达成**，物理直连在无授权下无写入点
5. **实验复现说明**：构建命令、测试命令、预期日志。→ 见 `analysis/root-cause.md` §7
6. **失败结论**：如果无授权方案不成立，指出具体阻塞检查或 API，而不是泛泛声称 macOS 不支持。→ 已完成，阻塞点 A–D 见 `analysis/root-cause.md` §8
7. **备选架构**：仅在直接物理 USB 方案确认不可行后提出，并明确与原始目标的偏差。→ 已完成，见 `analysis/root-cause.md` §9

## 12. 最重要的交接提醒

**不要再重复已经失败的 `IOHIDServiceClientSetProperty` 和 Event Service `IORegistryEntrySetCFProperty` 实验。**

这两个问题现在都有确定答案，无需再试探：

**A. WindowServer 的 `handle_digitizer_added` 如何获得 `displayUUID`？**
→ 它调用 `IOHIDServiceClientCopyProperty(service,"displayUUID")`，读的是**服务对象自己的顶层属性表**，服务端缓存，不搜索 IORegistry 父链。虚拟 HID 能给出该属性是因为 `IOHIDUserDevice` 的创建字典整体成为顶层属性（`IOHIDEventService::init` → `IOService::init(properties)`）。

**B. Samsung 物理 USB HID 能否在首次注册前提供 WindowServer 可接受的完整服务属性？**
→ 不能。物理服务的创建字典由内核 `AppleUserHIDEventDriver` 生成，`AppleUserHIDEventService::setSystemProperties()` 的白名单不含 `displayUUID`，其余键进 `HIDEventServiceProperties` 子字典；SIP 开启下没有任何用户态注入点能改变创建字典。

因此，**免授权（无 Apple 受限 entitlement）的“物理 USB 直连 + 原生多点触控”路线在本机不可行**。这是代码级结论，不是猜测。

请从这里继续，不要从零开始。

---

## 13. 下一步（架构决策阶段）

### 13.1 首要验证：DriverKit dext 能否发布顶层 `displayUUID`

这是唯一可能同时满足“物理直连 + SIP 开启 + 原生触控语义 + 用户可自行构建”的架构，但有一个未验证的关键点。

- 形态：`HIDDriverKit` 的 `IOUserHIDEventService`（或 USB 侧 `IOUserUSBHostDevice` 匹配 Samsung 的 `IOUSBHostInterface`）
- 权限：`com.apple.developer.driverkit` + `com.apple.developer.driverkit.transport.hid`（需 Apple 审批），dext 需用户在“系统设置 → 隐私与安全性”批准；**SIP 可保持开启**
- 未知点（`UNVERIFIED`）：`HIDDriverKit/IOHIDEventService.iig:362-381` 的 `SetProperties(..., SUPERDISPATCH)` 只把属性放进 IORegistry 的一个字典（即子字典路径），因此需要验证 dext 侧单键 `SetProperty(key,value)` 是否落到内核代理对象的**顶层**；若不能，则需在 service personality 里用 `IOPropertyMatch` / `IOResourceMatch` 之外的创建期属性注入（尚未找到文档）
- 验证方法：写最小 dext，在 `Start` 中 `SetProperty("displayUUID", <CFUUID>)` 后 `RegisterService()`，运行
  `hidutil property --matching '{"Product":"<dext product>"}' --get displayUUID`
  能读到 UUID 才说明可行；再看 WindowServer 日志是否出现 `digitizer added for display`

### 13.2 备选：申请 `com.apple.developer.hid.virtual.device`

- 与 VoidLink/Sunshine 同款路线：读平板 HID 报告 → `IOHIDUserDeviceCreateWithProperties` 创建带 `displayUUID` 的 16 点虚拟触控屏
- 偏差：WindowServer 看到的是虚拟设备而非物理设备直连，但输入语义仍是原生多点触控，不涉及串流与鼠标模拟
- 代价：需要 Apple 审核通过的 provisioning profile（Sunshine 的 `TeamIdentifier=FRL23UV4N9` 即此路径）

### 13.3 低成本收尾（可立即做）

1. `UNVERIFIED` 闭环：用 root 写 `/Library/Preferences/FeatureFlags/Domain/backboardd.plist`（`SupportExternalTouchscreen = { Enabled = 1; }`）+ 重启 WindowServer，确认 §2A 结论 5 的预测（仍失败）。仅作记录，不指望成功。
2. `UNVERIFIED`：确认 `kUSBContainerID` 旁路是否只在 USB4/DP-alt 显示器成立（本例 DM72u 为 DisplayPort，SAC/10085，无该键）。
3. 用 `probe/svcprop.c` 复测任意设备的服务属性（BackBoard 同款 API）；README 里可补一条：`./probe/svcprop SAMSUNG` 应显示 `displayUUID <NULL>`，这是最快的根因验证。

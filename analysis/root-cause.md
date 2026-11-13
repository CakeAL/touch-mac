# 根因报告 — macOS 为何接受虚拟触控服务、拒绝物理 USB HID 触控屏

**日期：** 2026-11-13
**环境：** macOS 27.3 (26C5035r) / arm64 / SIP enabled / 主显示器 DM72u `displayID=3` / UUID `8BF51424-0C57-4680-A7F9-9092F20311B9`
**被测设备：** `SAMSUNG_Android`（Android USB HID gadget，Digitizer page `0x0D` usage `0x04`，16 触点）
**结论状态标记：** `VERIFIED`（源码或反汇编直接证据）/ `INFERRED`（由多条证据推出，未被单点证明）/ `UNVERIFIED`（未验证）

---

## 0. 结论速览

1. `VERIFIED` — WindowServer 判定“是否接受某 HID 服务为触控源”的**唯一必需数据**是该服务对象自身的**顶层属性 `displayUUID`**。虚拟触控能成功，是因为它把这个属性写在**对象创建字典**里，而创建字典会被 `IOService::init(properties)` 直接注册成服务对象的顶层属性。
2. `VERIFIED` — 物理 USB HID 触控屏的 `displayUUID` 永远到不了服务顶层：物理设备的服务对象由内核驱动 `AppleUserHIDEventService` 单独创建，其 `setSystemProperties()` 只把一份**固定白名单**键提升为顶层属性，其余全部塞进 `HIDEventServiceProperties` 子字典。白名单里没有 `displayUUID`，而 `displayUUID` 也不是 HID 内核栈认识的键（IOHIDFamily 全源码 grep `uuid` 为空）。
3. `VERIFIED` — 因此 `IOHIDServiceClientCopyProperty(service, "displayUUID")` 对物理设备恒为 `NULL` → SkyLight 打印 `digitizer service has no usable displayUUID property` → BackBoard 打印 `ignoring digitizer event ... from unsupported service` → 事件被丢弃。日志里的 `<main>` 只是回退显示名，不是匹配成功。
4. `VERIFIED` — 无 Apple 授权时，**没有任何用户态 API 能写出这个顶层属性**：`IOHIDResourceDeviceUserClient::initWithTask()` 在内核里做 entitlement 门禁（`com.apple.developer.hid.virtual.device` 或私有的 `com.apple.hid.manager.user-access-device`）；用户态虚拟 HID 服务 `HIDVirtualEventService` 需要 Apple 私有 entitlement `com.apple.private.hid.client.event-dispatch`。
5. `INFERRED` — `backboardd/SupportExternalTouchscreen` 特性开关这条“Apple 官方外部触屏路径”在 macOS 上是死路：它依赖 `chamoisDisplayUUID`（`ivar +0xd8`），而全系统没有任何代码调用 `setChamoisDisplayUUID:`。
6. 结论：**在 SIP 开启、无 Apple 受限 entitlement 的前提下，物理 USB HID 触控屏无法获得 `BKDirectTouchState`**。可行架构只剩 DriverKit dext（需 Apple 签发 DriverKit entitlement）或申请 `com.apple.developer.hid.virtual.device` 的虚拟 HID 设备（Apple 审核的 provisioning profile）。详见 §10。

---

## 1. 判定点：WindowServer 里的两段代码

两处日志都在 **WindowServer** 进程内（`SkyLight` 弱链接了 `BackBoardHIDTouchEventProcessor` 与 `BackBoardHIDEventFoundation`；`VERIFIED`：`llvm-objdump --macho --dylibs-used SkyLight`，且系统内不存在 `/usr/libexec/backboardd`）。

### 1.1 SkyLight：`handle_digitizer_added`

- 符号：`WS::Displays::WSHIDDisplayEventListener::hid_event_callback(void*, void*, void*, __IOHIDEvent*)` @ `0x182b2c7d4`
- digitizer 分支（`VERIFIED`，反汇编）：
  - `IOHIDEventGetType(event) == 1`
  - `IOHIDEventGetIntegerValue` 字段 `0x10000 == 0xff15 (65301)`、`0x10001 == 3`、`0x10002 == 8`
  - `IOHIDEventGetDataValue(0x10003)` 的数据按两个 `int` 传给显示对象虚表 `+0x480`
  - 用 `IOHIDServiceClientCopyProperty(service, CFSTR("displayUUID"))` 取 UUID，再 `CFUUIDCreateFromString`
- 失败日志（`VERIFIED`）：`digitizer service has no usable displayUUID property; treating as no digitizer added`（`SkyLight` cstring `0x652143`，格式串 `0x182d0111f`）
- 旁路：同一函数还会读 `kUSBContainerID`（CFString `0x1e2250190`，15 字符）走另一条 add 路径；实测主显示器与 Samsung 的 USB 祖先链都没有 `kUSBContainerID`，该路径对本例不可用（`VERIFIED`：`ioreg -r -c IOUSBHostDevice` 无该键）。

### 1.2 BackBoard：`BKHIDDirectTouchEventProcessor`

- `-[BKHIDDirectTouchEventProcessor _handleDirectTouchEvent:service:]` @ `0x264114728`
  - `displayUUID` 为空且服务不是内建 digitizer → 打印 `ignoring digitizer event for display %{public}@ from unsupported service: ...`（日志调用点 `0x264114b34`）并**丢弃事件**
  - `displayUUID` 为空但服务“内建”且 `primaryUsagePage == 0xD`、`primaryUsage ∈ {1,4,32}` → 仍创建/复用 digitizer state
- `-[BKHIDDirectTouchEventProcessor _queue_displayUUIDForDigitizerService:]` @ `0x264113954`（完整反汇编已读）
  - 先取 `service.displayUUID`；为 `nil` 时再看 `_os_feature_enabled_impl("backboardd","SupportExternalTouchscreen")`，且要求 `isBuiltin == NO`、`eventSource == 2`、page `0xd`、usage `4`，满足则返回 `self+0xd8`（chamois display UUID），否则返回 `nil`
- `_queue_addDigitizerStateForService:` @ `0x264111d10`：`displayUUID` 为空时回退 `BKSDisplayUUIDMainKey`（主显示器）——这就是日志里出现 `<main>` 的原因，它只是**显示名回退**，与匹配成功无关
- `BKIOHIDService.displayUUID`（`BackBoardHIDEventFoundation`）：`ivar +0x78`，由 `_setUpInitialProperties` @ `0x1dd2b81bc` 通过 `[self propertyForKey:@"displayUUID"]` 填充；而 `-[BKIOHIDService propertyForKey:]` @ `0x1dd2b92c4` 最终调 `IOHIDServiceClientCopyProperty(serviceRef, key)`（`serviceRef` 存 `ivar +0x70`）

### 1.3 属性查询的真实语义

`VERIFIED`（`IOKit.framework` 反汇编，`__TEXT` vmaddr `0x184ebb000`）：

- `IOHIDServiceClientCopyProperty` @ `0x184ec50a0`（导出偏移 `0xA0A0`）
- 它先查本地属性缓存，再经 `IOHIDEventSystemClientCopyPropertyForService` @ `0x184ec5374` → `io_hideventsystem_copy_property_for_service(connection, serviceID, key)` 走 MIG/IPC 到 HID 事件系统服务端，取**该服务自己的属性表**
- 关键点：**不存在沿 IORegistry 父链搜索的逻辑**。这与实测“父链能搜到 `displayUUID`、但该 API 返回 NULL”完全一致（`VERIFIED`）

---

## 2. 虚拟侧（VoidLink / Sunshine）为何成功

`VERIFIED`（Sunshine 二进制反汇编 + IOHIDFamily 源码，双向闭环）：

1. `platf::macos::native_touch_t::connect(unsigned)` @ `0x1001dfce0` 用 `CFDictionaryCreate` 建 9 键字典（`0x1001e0068`）：`Product`、`VendorID=0x1209`、`ProductID=0x4c53`、`ReportDescriptor`、`Transport="Virtual"`、`displayUUID=CGDisplayCreateUUIDFromDisplayID(displayID)`、`CGDirectDisplayID`、`DisplayIntegrated=YES`、`DigitizerCollectionDispatch=YES`
2. `IOHIDUserDeviceCreateWithProperties(dict, NULL)` @ `0x1001e0084`
3. 之后轮询 `IOHIDUserDeviceCopyService` → `IORegistryEntryCreateIterator` 找到 `AppleUserHIDEventService` → 记 `RegistryID`。**全程没有再往服务写任何属性**——所有属性都在创建时给出
4. 内核里：`IOHIDUserDevice::initWithProperties()` → `super::init(properties)` → `IOHIDDevice::init()` → `IOHIDEventService::init()` → `IOService::init(properties)`
   - `IOHIDFamily/IOHIDEventService.cpp:191-193`：`bool IOHIDEventService::init(OSDictionary * properties) { if (!super::init(properties)) ... }`
   - `IOService::init(dict)` 把字典**整体注册为对象的顶层注册表属性**
   - 而 `IOHIDUserDevice` **本身就是** `IOHIDEventService`，所以 `displayUUID` 天然就是“服务对象的顶层属性”

这就是虚拟路线的全部秘密：**属性与对象同源**。

---

## 3. 物理侧（Samsung）为何失败

`VERIFIED`（IOHIDFamily 源码）：

1. 物理 USB HID 的对象图是两条：`AppleUserHIDDevice`（`0x10004bf31`）与 `AppleUserHIDEventService`（`0x10004bf39`）。后者由 `AppleUserHIDEventDriver` 单独创建，属性由驱动自己声明。
2. `IOHIDFamily/AppleUserHIDEventService.cpp:757-812`（`setSystemProperties`）只把固定白名单提升为顶层属性：
   - `propKeys[]`：`SurfaceDimensions`、`SensorPropertySupported`、`KeyboardEnabled`、`KeyboardEnabledByEvent`、`ReportInterval`、`SupportsGlobeKey`、`GameControllerFormFitting`、`KeyboardEnabledEvent`、`PointerAccelerationType`、`ScrollAccelerationType`、`GameControllerType`、`DigitizerGestureCharacterState`、`SupportsInk`、`SupportedEventMask`、`SupportedKeyboardUsagePairs`、`SupportedVendorUsagePairs`
   - 另有 `Digitizer` / `SensorProperties` / `Unicode` / `Elements` 等结构化键
   - 其余：`:806` 注释 `// Publish remaining properties under "HIDEventServiceProperties" key` → `super::setSystemProperties(properties)` → 落进子字典
3. `IOHIDEventService::setProperties`（`IOHIDFamily/IOHIDEventService.cpp:553-601`）把子字典 `HIDEventServiceProperties` 合并保存，并且只把 `kIOHIDPropagatePropertyKeys` 白名单里的键回写 provider。
4. `displayUUID` 不在以上任何白名单中；更要紧的是 **HID 内核栈根本不认识这个键**（`grep -ri uuid tools/IOHIDFamily` 结果为空）。它是 WindowServer/BackBoard 层的私有约定，由创建虚拟设备的进程提供。
5. 实测证据（`VERIFIED`）：
   - `hidutil property --matching '{"Product":"SAMSUNG_Android"}' --get displayUUID` → `(null)`
   - `ioreg -r -c AppleUserHIDEventService` 的 `HIDEventServiceProperties` 子字典里确实有 `displayUUID=8BF5...`、`CGDirectDisplayID=3`（说明注入值被存放了，但**没被提升**）
   - 向 `AppleUserHIDDevice` 注入 `displayUUID/CGDirectDisplayID/DigitizerCollectionDispatch` 返回 0 且可读回；向 Event Service 直接注入返回 0 但直接读回 NULL

### 3.1 为什么“在首次注册前提供属性”也无法绕过

要成为顶层属性，只有一条路：**在对象的创建字典里出现**（`IOService::init(properties)`）。物理服务的创建字典由内核驱动准备，用户态没有任何注入点：
- `IOHIDServiceClientSetProperty` → 服务端 `setProperties` → 子字典
- `IORegistryEntrySetCFProperty`（Event Service）→ 运行时属性表，不参与 `_setUpInitialProperties` 的 `propertyForKey:` 查询
- `IOHIDDeviceSetProperty`（设备对象）→ 只改设备对象，且 `setSystemProperties` 仍过滤

---

## 4. 被证伪的假说

| 假说 | 结论 | 证据 |
|---|---|---|
| H1：属性有“注册时机窗口”，早写就能被读到 | 伪 | 顶层属性只能在创建时给出；`CopyProperty` 读服务端属性表，不读父链 |
| H2：WindowServer 还有别的接受条件（如 `DisplayIntegrated`、`DigitizerCollectionDispatch`） | 伪 | 物理服务顶层已有 `DisplayIntegrated=1`（`IOHIDEventService.cpp:783` 对 Digitizer usage 自动设置），仍被拒；唯一判据是 `displayUUID` |
| H3：写 `HIDEventServiceProperties` 子字典就够了 | 伪 | 子字典不被 `IOHIDServiceClientCopyProperty` 读取（实测 NULL） |
| H4：用 `backboardd/SupportExternalTouchscreen` 开关走 Apple 官方外部触屏路径 | 伪（`INFERRED`，证据强） | 开关只让 `_queue_displayUUIDForDigitizerService:` 回退到 `chamoisDisplayUUID`；而 `setChamoisDisplayUUID:` 在全系统只出现 2 次（方法名 + 其 block 符号），无 `_objc_msgSend$setChamoisDisplayUUID:` 桩，`SkyLight`/其他 BackBoard 框架为 0 次 → 该 ivar 永不被赋值 |
| H5：改 HID 描述符/让设备自称内建（`Built-In=1`） | 伪（SIP 下） | 内建分支确实绕过 `displayUUID`，但 `isBuiltin` 来自服务顶层 `Built-In` 属性，只能由内核驱动在创建时给（USB 设备恒为 0） |
| H6：`kUSBContainerID` 旁路（SkyLight 另一条 add 路径） | 不可用 | Samsung 的 USB 祖先链与显示器都没有 `kUSBContainerID` |

> H4 的开关本身仍未实机验证；若要试，需要 root 写 `/Library/Preferences/FeatureFlags/Domain/backboardd.plist` 并重启 WindowServer。按代码证据预期无效（`chamoisDisplayUUID` 恒 `nil`）。

---

## 5. 权限矩阵（SIP 开启，无 Apple 授权）

| 目标 | 门禁位置 | 所需 entitlement | 普通人可得？ |
|---|---|---|---|
| 让**物理**服务的 `displayUUID` 成为顶层属性 | 内核对象创建时 | 需内核/驱动创建该对象 | 否（SIP 下无注入点） |
| 创建**虚拟 HID 设备**（创建属性即顶层属性，可行路线） | `IOHIDFamily/IOHIDResourceUserClient.cpp:120-150`（`IOHIDResourceDeviceUserClient::initWithTask`） | `com.apple.developer.hid.virtual.device`（`IOHIDResourceUserClient.cpp:33`）**或** `com.apple.hid.manager.user-access-device`（私有，`_privileged=true`） | 需 Apple 审核的 provisioning profile；自签带假 entitlement 会被 `SIGKILL`（实测 exit 137） |
| 创建**虚拟 HID 服务** `HIDVirtualEventService` | `HID/PrivateHeaders/HIDVirtualEventService.h:165` | `com.apple.private.hid.client.event-dispatch` | 否（Apple 私有） |
| 事件系统客户端特权类型 | `HID/Headers/HIDEventSystemClient.h:28,33,44` | `com.apple.private.hid.client.admin` / `...event-monitor` | 否 |
| DriverKit HID 事件服务（dext） | dext 加载 + 匹配 | `com.apple.developer.driverkit` + `com.apple.developer.driverkit.transport.hid`（`IOHIDInterface.cpp:983-1014` 会发布 `IOServiceDEXTEntitlements`） | 需 Apple 批准开发者 entitlement + 用户在系统设置批准 dext；SIP 可保持开启 |
| 读物理 HID 报告（不用来注册触控） | 无 | 无 | 是（`IOHIDDevice` 打开即可，实测可读） |

补充：`HID.framework` 里的 `HIDVirtualEventService` 类族（`HIDVirtualEventService`、`HIDEventSystemClient initWithType:` 等）只是 `IOHIDVirtualServiceClient*` 的 ObjC 封装，门禁相同（`VERIFIED`：`probe/hidclass.m` 运行时枚举类、方法、ivar）。

---

## 6. 最小 PoC 状态

**未达成。** 已建成的探针与用途：

| 文件 | 用途 |
|---|---|
| `probe/touch-check.c` | 读 Samsung Event Service 及父链属性 |
| `probe/touch-inject.c` | 三处属性注入 + 读回（已证明无效，勿重复） |
| `probe/vhid_test.c` | 未授权创建虚拟 HID 设备（返回 0）/ 自签带 entitlement（SIGKILL） |
| `probe/ffprobe.c` | 查询 `_os_feature_enabled_impl`；`FEATUREFLAGS_ENABLED=backboardd/SupportExternalTouchscreen ./ffprobe backboardd SupportExternalTouchscreen` → 1（格式已验证） |
| `probe/hidclass.m` | 枚举 `HIDVirtualEventService` 方法/ivar（18 个实例方法、5 个 ivar） |
| `probe/hidproto.m` | 枚举 HID.framework 导出的类 |
| `tools/cache_stubs.py` | 共享缓存 stub → 导入符号 |
| `tools/extractor/` | dyld shared cache 提取 |

---

## 7. 复现要点

```bash
# 1) 设备与服务
hidutil list | grep -i samsung
ioreg -r -c AppleUserHIDEventService -l | grep -A3 HIDEventServiceProperties

# 2) 复现被拒日志（从平板侧发一次 tap）
log stream --predicate 'subsystem CONTAINS "SkyLight" OR subsystem CONTAINS "BackBoard"' --level debug
#   期望: digitizer service has no usable displayUUID property ...
#         ignoring digitizer event for display <main> from unsupported service ...

# 3) 顶层属性缺失（决定性证据）
hidutil property --matching '{"Product":"SAMSUNG_Android"}' --get displayUUID   # → (null)

# 4) 虚拟对照组（VoidLink/Sunshine 运行时）
hidutil property --matching '{"Product":"VoidLink HID Touchscreen"}' --get displayUUID
```

验收标准（原生触控）：在“无第三方鼠标模拟”前提下，`WindowServer` 侧不再出现上述两条日志，且系统设置 → 辅助功能/触控板下能看到该显示器被标记为支持触摸（`touchCaps` 变化）。

---

## 8. 失败结论（具体阻塞点，而非“macOS 不支持”）

1. **阻塞点 A**：`displayUUID` 必须是 `IOHIDEventService` 对象的顶层注册表属性；顶层属性只在 `IOService::init(properties)` 时写入。物理 USB 服务的创建字典由内核 `AppleUserHIDEventDriver` 生成，用户态无注入点。
2. **阻塞点 B**：`AppleUserHIDEventService::setSystemProperties()` 的白名单不含 `displayUUID`，其余键进 `HIDEventServiceProperties` 子字典，而 BackBoard 只查顶层。
3. **阻塞点 C**：用户态“造一个服务”的两种 API 都被 entitlement 挡住——`IOHIDResourceDeviceUserClient::initWithTask`（`com.apple.developer.hid.virtual.device` / 私有 `com.apple.hid.manager.user-access-device`）与 `HIDVirtualEventService`（私有 `com.apple.private.hid.client.event-dispatch`）。
4. **阻塞点 D**：Apple 官方外部触屏开关 `backboardd/SupportExternalTouchscreen` 的回退值 `chamoisDisplayUUID` 在 macOS 上永不被赋值，且该开关默认关闭、需要 root 才能写覆盖 plist。

---

## 9. 备选架构（按可行性排序）

### A. DriverKit HID 驱动（dext）— 唯一“物理直连 + SIP 开启 + 原生语义”
- 形态：`HIDDriverKit` 的 `IOUserHIDDevice` / `IOUserHIDEventService`（或 `USBDriverKit` 匹配 `IOUSBHostInterface`），在 dext 内发布事件服务并派发 digitizer 事件。
- 权限：`com.apple.developer.driverkit` + `com.apple.developer.driverkit.transport.hid`（Apple 申请表审批），应用/驱动需 notarize，用户在“系统设置 → 隐私与安全性”批准 dext。SIP 保持开启。
- 未验证（关键）：dext 能否在其事件服务上写出**顶层** `displayUUID`。`HIDDriverKit/IOHIDEventService.iig:362-381` 明确 `SetProperties(..., SUPERDISPATCH)` 只会“added to a dictionary in IOReg”，即子字典路径；需验证 dext 侧 `SetProperty(key,value)`（单键）是否落到内核代理对象顶层，或是否可用 personality 属性在创建时注入。
- 偏差：需要 Apple 授权与用户批准，工程量大（周级）；但这是商业触控驱动（UPDD 等）在 Apple Silicon 上的实际做法。

### B. 申请 `com.apple.developer.hid.virtual.device`，用虚拟 HID 设备桥接（VoidLink 同款）
- 形态：一个签名应用读平板 HID 报告 → `IOHIDUserDeviceCreateWithProperties`（`displayUUID` + `DisplayIntegrated` + `DigitizerCollectionDispatch`）→ 虚拟 16 点触控屏。
- 偏差：WindowServer 看到的是虚拟设备（非物理设备直连），但输入语义是**原生多点触控**、不涉及串流、不涉及鼠标模拟。需要 Apple 审核通过的 provisioning profile（Sunshine 的 `TeamIdentifier=FRL23UV4N9` 就是这么做的）。
- 现状：本机普通进程创建返回 `0x0`；自签带该 entitlement 被 `SIGKILL`（exit 137）。

### C. 采购/沿用已授权产品（VoidLink）
- 已可用，但用户明确不把它当最终方案。

### 已排除
- CGEvent 鼠标模拟、Trackpad 手势模拟（用户否决）。
- 视频串流（用户否决）。
- 内核扩展 kext（SIP 开启下不可加载第三方 kext）。
- 改 HID 描述符 / 自称内建 digitizer（顶层 `Built-In` 无法由用户态写入）。

---

## 10. 未验证项 / 下一步

1. `UNVERIFIED`：DriverKit dext 的事件服务能否发布顶层 `displayUUID`（决定架构 A 是否成立）。验证方式：写最小 dext（需 entitlement），在其 `Start` 里 `SetProperty("displayUUID", uuid)` 后 `RegisterService()`，再用 `hidutil property --get displayUUID` 读。
2. `UNVERIFIED`：`/Library/Preferences/FeatureFlags/Domain/backboardd.plist` 覆盖 + 重启 WindowServer 是否让 `backboardd/SupportExternalTouchscreen` 生效（需 root；按 §4-H4 预期无效，仅作闭环记录）。
3. `UNVERIFIED`：`kUSBContainerID` 旁路是否只在 USB4/DP-alt 显示器上成立（本例显示器为 DisplayPort，SAC/10085，无该键）。
4. 待办（低成本）：把本报告 §1-§3 的地址与结论回写 `Handoff.md`，并把 `probe/hidclass.m`、`probe/hidproto.m` 纳入版本管理。

---

## 附录：关键证据地址表

| 对象 | 地址/位置 |
|---|---|
| SkyLight `hid_event_callback` | `0x182b2c7d4` |
| SkyLight `handle_digitizer_added` key `displayUUID` | CFString `0x1e225ddf0`（11 字符） |
| SkyLight `start_iohid_event_system_client` block | `0x182b2cc4c` |
| SkyLight 失败日志 | cstring `0x652143`，格式串 `0x182d0111f` |
| IOKit `IOHIDServiceClientCopyProperty` | `0x184ec50a0`（导出 `0xA0A0`） |
| IOKit `IOHIDEventSystemClientCopyPropertyForService` | `0x184ec5374` |
| bbtouch `_handleDirectTouchEvent:service:` | `0x264114728`，日志 `0x264114b34` |
| bbtouch `_queue_displayUUIDForDigitizerService:` | `0x264113954`（flag 读入 `0x264113980-0x264113990`） |
| bbtouch `_isPossibleChamoisTouchscreen:` | `0x2641138cc`（同一组判据） |
| bbtouch `_queue_addDigitizerStateForService:` | `0x264111d10` |
| bbtouch chamois getter/setter | `0x2641135cc` / `0x2641136d0` |
| BBHIDEventFoundation `BKIOHIDService propertyForKey:` | `0x1dd2b92c4`；`_setUpInitialProperties` `0x1dd2b81bc`；`displayUUID` ivar `+0x78`；服务引用 ivar `+0x70` |
| Sunshine `native_touch_t::connect` | `0x1001dfce0`；字典 `CFDictionaryCreate` `0x1001e0068`；创建调用 `0x1001e0084` |
| 共享缓存基址 / SkyLight 二进制 | `0x180000000` / `/private/var/folders/ff/3m8k2fcs3nzd589g8lwbhghw0000gn/T/dsc-out/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight` |

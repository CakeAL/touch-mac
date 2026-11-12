# touch-mac

把安卓平板变成 Mac 的触控屏（macOS 27.2+），让系统把那块屏当成真正的触控显示器——红绿灯放大、菜单加高、App 收到原生 direct touch。

## 当前状态（2026-11-12）

| 项 | 结果 |
| --- | --- |
| 安卓（root）经 USB HID gadget 接入 | ✅ Mac 端 `touchCaps = 1`，已被识别为触控屏 |
| 软件虚拟触屏（`IOHIDUserDeviceCreate*`） | ❌ macOS 27.2 内核拒绝，见 [probe/README.md](probe/README.md) |
| 视频链路 / 多点 / S Pen | ⏳ 待做 |

结论：在 27.2 上走**真 USB HID 设备**，Mac 侧不需要注入代码，系统自己接管触摸。

## 结构

```
touch-mac/
├── plan.md                  # 实施方案：架构、协议、阶段、风险
├── android/
│   └── hid_gadget.sh        # root 平板 → USB HID 触屏（check/setup/tap/rollback）
├── mac/
│   ├── touchbridge.m        # 软件虚拟触屏（27.2 上不可用，保留作参考）
│   └── TouchLab/            # 验证 App：手势识别器 + NSTouch 日志
├── probe/
│   ├── README.md            # 探针结论：27.2 的 entitlement 墙、隐藏接口清单
│   ├── screeninfo.m         # 打印显示器 touchCapabilities
│   ├── vnat.m / vkeyb.m / vtouch.m / vtcreate.m   # 虚拟 HID 尝试（预期失败）
│   └── build.sh
└── tools/
    ├── send_touch.py        # 给 touchbridge 发触摸（联调）
    └── demo_tap.py          # 单指 + 双指演示
```

## 快速开始

### 1. 编译验证工具

```bash
./probe/build.sh            # → probe/build/screeninfo 等
./mac/TouchLab/build.sh     # → mac/TouchLab/build/TouchLab.app
```

### 2. 平板侧（root）

```bash
adb push android/hid_gadget.sh /data/local/tmp/
adb tcpip 5555 && adb connect <平板IP>:5555     # 先切无线，USB 会断
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh check'
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh setup'
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh tap'
```

回滚：`adb shell su -c 'sh /data/local/tmp/hid_gadget.sh rollback'`（adb 掉了就重启平板）。

### 3. Mac 侧验证

```bash
./probe/build/screeninfo                          # 期望 touchCaps=1
./mac/TouchLab/build/TouchLab.app/Contents/MacOS/TouchLab /tmp/touchlab.log
```

`/tmp/touchlab.log` 出现 `[touch] began/moved/ended` 表示拿到原生触摸；只有 `[mouse]` 则还是鼠标模拟。

## 下一步

1. **多点**：把 gadget 描述符从单指换成 16 指（见 [plan.md](plan.md) 第 5 节），验证双指缩放/滚动。
2. **触控 UI**：打开 Finder 看红绿灯是否放大、菜单是否加高。
3. **视频**：ScreenCaptureKit + VideoToolbox → 平板 MediaCodec，USB 或 WiFi 传输。
4. **S Pen**：第二个 HID 设备（Pen collection，带压感/倾斜/悬停）。

## 背景

- Apple TN3212：Sidecar 触摸只能从 `NSGestureRecognizer` 收到，`NSIsTouchNative` 可关闭 AppKit 的鼠标模拟。
- 27.2 的软件虚拟触屏被 `IOHIDResourceDeviceUserClient` 的 entitlement 拦住（root 也不行），细节与证据见 [probe/README.md](probe/README.md)。

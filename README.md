# touch-mac

把安卓平板变成 Mac 的触控屏（macOS 27.2+），让系统把那块屏当成真正的触控显示器——红绿灯放大、菜单加高、App 收到原生 direct touch。

## 当前状态（2026-11-12）

| 项 | 结果 |
| --- | --- |
| 安卓（root）经 USB HID gadget 接入 | ✅ Mac 端 `touchCaps = 1`，已被识别为触控屏 |
| 单指点击（`setup` + `tap`） | 🟡 已具备，待 Mac 端实测 |
| 多点（`setup-mt` + 安卓 App） | 🟡 代码完成，待实测 |
| 软件虚拟触屏（`IOHIDUserDeviceCreate*`） | ❌ macOS 27.2 内核拒绝，见 [probe/README.md](probe/README.md) |
| 视频链路 / S Pen | ⏳ 待做 |

结论：在 27.2 上走**真 USB HID 设备**，Mac 侧不需要注入代码，系统自己接管触摸。

## 结构

```
touch-mac/
├── plan.md                  # 实施方案：架构、协议、阶段、风险
├── android/
│   ├── hid_gadget.sh        # root 平板 → USB HID 触屏（check/setup/setup-mt/tap/tap2/rollback）
│   └── app/                 # 安卓 App：全屏触摸面 → /dev/hidg0（16 指，97 字节报告）
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
./android/app/build.sh      # → android/app/build/TouchPad.apk（不用 Gradle）
```

### 2. 平板侧（root）

```bash
adb push android/hid_gadget.sh /data/local/tmp/
adb tcpip 5555 && adb connect <平板IP>:5555     # 先切无线，USB 会断
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh check'
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh setup'      # 单指，先用 tap 验证链路
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh tap'
```

回滚：`adb shell su -c 'sh /data/local/tmp/hid_gadget.sh rollback'`。

> ⚠️ **失联救援**：绑定 gadget 后，USB 上的 adb（f_fs）会随默认 gadget `g1` 一起被解绑，有线 adb 必然消失。
> 如果此时又没开无线 adb，唯一的恢复办法是在平板上**重启**（configfs 的 gadget 只存在于运行时，不持久化），
> 或者在本机的 root 终端（Termux 等）里跑 `rollback`。
> 所以脚本在绑 UDC 前会检查 `service.adb.tcp.port`，没开无线 adb 会拒绝执行；确实要冒险就加 `--force`。

### 2b. 多点（16 指）

```bash
# 换 16 指描述符（97 字节报告），重新枚举
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh setup-mt'
adb shell su -c 'sh /data/local/tmp/hid_gadget.sh tap2'       # 两指捏合，应触发缩放

# 装 App：整个平板变成触摸面，每根手指实时写进 /dev/hidg0
./android/app/build.sh
adb install -r android/app/build/TouchPad.apk
```

App 用 `su -c "cat > /dev/hidg0"` 的管道写报告（绕开 SELinux 对普通 App 写 hidg 设备的限制），所以：
第一次打开会弹 root 授权，必须允许；没跑 `setup-mt` 时状态栏会提示写入失败。

### 3. Mac 侧验证

```bash
./probe/build/screeninfo                          # 期望 touchCaps=1
./mac/TouchLab/build/TouchLab.app/Contents/MacOS/TouchLab /tmp/touchlab.log
```

`/tmp/touchlab.log` 出现 `[touch] began/moved/ended` 表示拿到原生触摸；只有 `[mouse]` 则还是鼠标模拟。

> 注意：App 是全屏黑底，视频镜像（第 3 阶段）还没接上。现阶段它只用来验证「平板上的手指 → Mac 原生直触」这条链路；
> 等镜像做好后，会改成透明浮层或把触摸采集并进镜像播放器。

## 下一步

1. **实测多点**：`setup-mt` + App，在访达/Safari 里试双指缩放和滚动，确认 16 指报告被正确解析。
2. **触控 UI**：打开 Finder 看红绿灯是否放大、菜单是否加高。
3. **视频**：ScreenCaptureKit + VideoToolbox → 平板 MediaCodec，USB 或 WiFi 传输；App 改成透明浮层或内嵌播放器。
4. **S Pen**：第二个 HID 设备（Pen collection，带压感/倾斜/悬停）。

## 背景

- Apple TN3212：Sidecar 触摸只能从 `NSGestureRecognizer` 收到，`NSIsTouchNative` 可关闭 AppKit 的鼠标模拟。
- 27.2 的软件虚拟触屏被 `IOHIDResourceDeviceUserClient` 的 entitlement 拦住（root 也不行），细节与证据见 [probe/README.md](probe/README.md)。

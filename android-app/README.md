# TouchBridge（平板侧触控转发 App）

一个不依赖 root、不依赖第三方 SDK 的最小 Android 应用：把平板的多点触控原样打包，
经 `adb reverse` 送到 Mac 上的 `bridge/touchd.py`，再由 `bridge/client` 通过 Moonlight
协议转发给已签名的 Sunshine，最终由 Sunshine 的 libvirtualhid 创建 VoidLink 原生触控屏。

平板端只做“采集 + 发送”，不碰 HID，也不需要任何系统权限。

## 构建

```bash
cd android-app
./build.sh          # 用 SDK 自带 aapt2/d8/apksigner 直接打包，不需要 gradle
```

产物：`android-app/build/touchbridge.apk`（debug 签名，可直接安装）。

依赖：Android SDK（`~/Library/Android/sdk`，用到 `build-tools/36.0.0` 与
`platforms/android-37.0/android.jar`）、`javac`、`keytool`。

## 安装与运行

```bash
adb install -r android-app/build/touchbridge.apk
adb shell am start -n com.touchbridge.pad/.MainActivity
```

App 会占满屏幕、黑底，左上角显示链路状态：

```
adb reverse tcp:47777 · connected
touching: 0
```

`no link` 表示 Mac 侧还没起 `bridge/session.sh --net`。

## Mac 侧

```bash
adb reverse tcp:47777 tcp:47777     # session.sh --net 会自动执行
bridge/session.sh --net
```

## 协议（文本行，ASCII）

```
d <id> <x> <y>    按下（id = Android pointerId，0..31）
m <id> <x> <y>    移动
u <id> <x> <y>    抬起
c                 取消全部触点
```

坐标归一化到 `0..1`，**原点在左下角**（与 Moonlight 的触控坐标系一致，y 需要从
Android 的左上原点翻转）。每行一条，TCP 流式传输。

## 已知边界

- 只有 `ACTION_DOWN/MOVE/UP` 与多指 `POINTER_DOWN/POINTER_UP`；没有压力/接触面积
  （Moonlight 协议里这两个字段填 0）。
- 120 Hz 上报；移动事件不做去抖，直接透传。
- 写 socket 必须走独立线程：Android 在主线程禁止网络 I/O
  （否则 `NetworkOnMainThreadException`，早期版本的实现就踩了这个坑）。

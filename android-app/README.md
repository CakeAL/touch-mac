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

App 会占满屏幕、黑底，中间是视频区 + 和 Mac 显示器同宽高比的活动框（默认 16:9），
左上角显示状态：

```
adb reverse tcp:47777 · connected
video: connected · playing 1920x1080
touching: 0   frame: 1.778 (host)
只有框内区域会转发触摸
```

`no link` 表示 Mac 侧还没起 `bridge/session.sh --net`；`video:` 行显示视频链路与解码
状态（`no stream, retry 400ms` 表示 Mac 侧还没推流，框内会显示“等待画面…”）。

只有框内的触摸会被转发，框内坐标线性映射到 Mac 全屏，所以平板上看到的就是
Mac 屏幕的等比缩放，不会因为两机比例不同而拉歪。比例由 Mac 侧下发（见下），
想换比例改 `session.sh --aspect` 即可。

## 视频层（H.264 硬解）

视频和触控是两条独立链路：触控走 47777 的文本行，视频走 47779 的二进制流，
互不阻塞（视频断线不影响触控，反之亦然）。

- 显示：`FrameLayout` 里底层是 `SurfaceView`，位置和大小按 `TouchSurface` 算出的活动框
  每帧对齐；上层 `TouchSurface` 改成透明背景，只画活动框描边、触点圆环和状态文字。
  触摸逻辑与坐标映射完全没动。
- 解码：`VideoClient` 里两个线程 —— `video-net` 收流，`video-dec` 用
  `MediaCodec.createDecoderByType("video/avc")` 送帧（`KEY_LOW_LATENCY=1`，API 30+），
  输出 `releaseOutputBuffer(index, true)` 直接渲染到 SurfaceView。帧队列满时丢掉积压并
  等下一个 IDR 重新同步；surface 销毁（退到后台）时先释放 codec，回来再重建。
- 分辨率变化（Mac 侧改窗口/改采集参数）会收到新的 CONFIG，codec 自动 stop/release 重建。
- 断线每 400 ms 重连，连接和重连都在后台线程，不阻塞 UI。

```bash
adb reverse tcp:47779 tcp:47779     # Mac 侧脚本建立
```

协议（每条消息 `u8 type` + `u32 BE length` + payload）：

```
0x01 CONFIG  Annex-B 字节流，含 SPS/PPS（00 00 00 01 起始码），整段作为 csd-0
0x02 FRAME   u64 BE pts_us + u8 flags(bit0=1 关键帧) + Annex-B access unit
```

## Mac 侧

```bash
adb reverse tcp:47777 tcp:47777     # session.sh --net 会自动执行
adb reverse tcp:47779 tcp:47779     # 视频端口
bridge/session.sh --net
```

## 协议（文本行，ASCII）

```
d <id> <x> <y>    按下（id = Android pointerId，0..31）
m <id> <x> <y>    移动
u <id> <x> <y>    抬起
c                 取消全部触点
```

坐标归一化到 `0..1`，**原点在左上角**：Sunshine 把这个 y 直接写进 HID digitizer 的
y（0 = 屏幕顶端），WindowServer 再转成 AppKit 的左下原点坐标。实测
`AppKit.y = (1 - y) * screenHeight`，所以**不要**再翻转一次，否则上下颠倒。

Mac 侧连接成功后会先下发一行握手信息：

```
#aspect 1.777778        Mac 主显示器的宽高比（session.sh 自动探测）
```

App 收到后把活动框调整成该比例。

## 已知边界

- 只有 `ACTION_DOWN/MOVE/UP` 与多指 `POINTER_DOWN/POINTER_UP`；没有压力/接触面积
  （Moonlight 协议里这两个字段填 0）。
- 120 Hz 上报；移动事件不做去抖，直接透传。
- 写 socket 必须走独立线程：Android 在主线程禁止网络 I/O
  （否则 `NetworkOnMainThreadException`，早期版本的实现就踩了这个坑）。

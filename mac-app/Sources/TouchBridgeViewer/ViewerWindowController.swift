import AppKit

/// 小窗口：画面 + 鼠标模拟单点触控 + 顶部状态。
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    private let view: VideoView
    private let touch: TouchClient
    private let video: VideoClient
    private var statusTimer: Timer?
    private var didShutdown = false
    private var didRunSelfTest = false
    private let selfTestEnabled = ProcessInfo.processInfo.environment["TOUCHBRIDGE_SELFTEST"] == "1"

    init(
        host: String = ProcessInfo.processInfo.environment["TOUCHBRIDGE_HOST"] ?? "127.0.0.1",
        touchPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["TOUCHBRIDGE_TOUCH_PORT"] ?? "") ?? 47777,
        videoPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["TOUCHBRIDGE_VIDEO_PORT"] ?? "") ?? 47779
    ) {
        let contentSize = NSSize(width: 860, height: 540)
        // 非激活面板：悬浮置顶，但点它不会把本 App 拉到前台、不抢键盘焦点。
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "TouchBridge 本机预览"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        self.view = VideoView(frame: NSRect(origin: .zero, size: contentSize))
        self.touch = TouchClient(host: host, port: touchPort)
        self.video = VideoClient(host: host, port: videoPort)

        super.init(window: window)

        window.contentView = view
        window.delegate = self

        video.onFrame = { [weak self] imageBuffer in
            self?.view.display(imageBuffer)
        }
        video.requestKeyframe = { [weak self] in
            self?.touch.requestKeyframe()
        }
        video.onStateChange = { [weak self] in
            self?.refreshStatus()
        }
        touch.onAspectChange = { [weak self] in
            guard let self else { return }
            self.view.bridgeAspect = CGFloat(self.touch.aspect)
        }
        touch.onStateChange = { [weak self] in
            guard let self else { return }
            print("[touch] \(self.touch.isConnected ? "已连接" : "断开")")
            self.refreshStatus()
        }
        view.onTouch = { [weak self] kind, x, y in
            let mapped: TouchClient.Kind
            switch kind {
            case .down: mapped = .down
            case .move: mapped = .move
            case .up: mapped = .up
            }
            self?.touch.sendTouch(mapped, x: x, y: y)
        }
        view.onReleaseAll = { [weak self] in
            self?.touch.releaseAll()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // orderFront 而非 makeKeyAndOrderFront：只显示，不夺焦点。
        window?.orderFront(sender)
        start()
    }

    private func start() {
        guard statusTimer == nil else { return }
        video.start()
        touch.start()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        refreshStatus()
        maybeRunSelfTest()
    }

    /// 开发自检：向自己的窗口投递一次 按下→拖动→抬起，验证鼠标→触控换算链路。
    /// 仅在 TOUCHBRIDGE_SELFTEST=1 时启用（配合 mock 端口使用，避免真实点击屏幕）。
    private func maybeRunSelfTest() {
        guard selfTestEnabled, !didRunSelfTest else { return }
        didRunSelfTest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runSyntheticDrag()
        }
    }

    private func runSyntheticDrag() {
        guard let window else { return }
        let contentHeight = window.contentView?.bounds.height ?? 540
        let width = window.contentView?.bounds.width ?? 860
        func windowPoint(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
            NSPoint(x: width * fx, y: contentHeight * (1 - fy))
        }

        let start = windowPoint(0.30, 0.35)
        let end = windowPoint(0.65, 0.70)
        print("[selftest] drag \(start) -> \(end)")

        let timestamp = ProcessInfo.processInfo.systemUptime
        let common: (NSEvent.EventType, NSPoint) -> NSEvent? = { type, point in
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = common(.leftMouseDown, start) {
            window.sendEvent(down)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let drag = common(.leftMouseDragged, end) {
                window.sendEvent(drag)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if let up = common(.leftMouseUp, end) {
                window.sendEvent(up)
            }
        }
    }

    /// 失焦时补发抬起，避免桥侧触点卡住。
    func releaseTouchIfNeeded() {
        view.cancelTouch()
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        statusTimer?.invalidate()
        statusTimer = nil
        view.cancelTouch()
        view.onReleaseAll?()
        video.stop()
        touch.stop()
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    private func refreshStatus() {
        // 看门狗：非激活面板偶尔收不到 mouseUp，物理按键已松开就补发抬起，避免触点卡在按下态。
        if !selfTestEnabled && view.isTouching && (NSEvent.pressedMouseButtons & 1) == 0 {
            view.cancelTouch()
        }
        let stats = video.snapshot()
        var line: String
        if stats.width > 0 {
            line = "视频 \(stats.width)×\(stats.height)"
            if stats.fps > 0 {
                line += String(format: " · %.0f fps", stats.fps)
            }
            if stats.latencyMs >= 0 {
                line += String(format: " · ~%.1f ms", stats.latencyMs)
            }
            if stats.decoded == 0 {
                line += " · 等待首帧"
            }
        } else {
            line = stats.state
        }

        line += "  ·  触控 " + (touch.isConnected ? "已连接" : "重连中")
        if view.isTouching {
            line += "  ·  触点 0 按下"
        }
        view.setStatus(line)
    }
}

import AppKit
import CoreVideo

/// 画面 + 交互视图：显示解码帧，鼠标按下/拖动/抬起映射成单点触控。
final class VideoView: NSView {
    enum TouchKind {
        case down
        case move
        case up
    }

    /// 归一化坐标（0..1，原点左上）交给触控客户端。
    var onTouch: ((TouchKind, Float, Float) -> Void)?
    /// 需要释放全部触点时回调（窗口关闭等）。
    var onReleaseAll: (() -> Void)?

    private let videoLayer = CALayer()
    private let hud = HUDView()

    private(set) var videoSize: CGSize = .zero
    /// 桥上报的画面宽高比，等首帧到达前用来占位。
    var bridgeAspect: CGFloat = 0 {
        didSet {
            needsLayout = true
            hud.needsDisplay = true
        }
    }

    private(set) var isTouching = false
    private var lastPoint: CGPoint?
    private var contentRect: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resize
        videoLayer.magnificationFilter = .linear
        layer?.addSublayer(videoLayer)

        hud.autoresizingMask = [.width, .height]
        addSubview(hud)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // MARK: - 布局

    override func layout() {
        super.layout()

        let aspect = displayAspect
        var rect = bounds
        if aspect > 0, bounds.width > 0, bounds.height > 0 {
            var width = bounds.width
            var height = width / aspect
            if height > bounds.height {
                height = bounds.height
                width = height * aspect
            }
            rect = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
        }
        contentRect = rect

        // 视图是 flipped，而 CALayer 子层坐标系仍是左下原点，这里换算一次。
        videoLayer.frame = CGRect(
            x: rect.minX,
            y: bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        hud.frame = bounds
        hud.contentRect = rect
        hud.needsDisplay = true
    }

    private var displayAspect: CGFloat {
        if videoSize.width > 0, videoSize.height > 0 {
            return videoSize.width / videoSize.height
        }
        if bridgeAspect > 0 {
            return bridgeAspect
        }
        return 16.0 / 9.0
    }

    // MARK: - 显示

    func display(_ imageBuffer: CVImageBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        if width > 0, height > 0, videoSize != CGSize(width: width, height: height) {
            videoSize = CGSize(width: width, height: height)
            needsLayout = true
        }
        videoLayer.contents = imageBuffer
    }

    func setStatus(_ text: String) {
        guard hud.statusText != text else { return }
        hud.statusText = text
        hud.needsDisplay = true
    }

    // MARK: - 鼠标 → 单点触控

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = normalized(point, clamp: false) else {
            return // 画面外按下不产生触控
        }
        isTouching = true
        lastPoint = point
        hud.setTouch(visible: true, at: point)
        onTouch?(.down, x, y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouching else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = normalized(point, clamp: true) else { return }
        lastPoint = point
        hud.setTouch(visible: true, at: point)
        onTouch?(.move, x, y)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        let point = convert(event.locationInWindow, from: nil)
        let (x, y) = normalized(point, clamp: true) ?? (0.5, 0.5)
        endTouch(x: x, y: y)
    }

    /// 失焦等场景：补发抬起，避免桥侧触点卡住。
    func cancelTouch() {
        guard isTouching, let point = lastPoint, let (x, y) = normalized(point, clamp: true) else {
            isTouching = false
            hud.setTouch(visible: false, at: nil)
            return
        }
        endTouch(x: x, y: y)
    }

    private func endTouch(x: Float, y: Float) {
        isTouching = false
        lastPoint = nil
        hud.setTouch(visible: false, at: nil)
        onTouch?(.up, x, y)
    }

    /// 视图坐标 → 归一化坐标（原点左上）。框外按下忽略，拖动时夹到 0..1。
    private func normalized(_ point: CGPoint, clamp: Bool) -> (Float, Float)? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }

        var x = (point.x - rect.minX) / rect.width
        var y = (point.y - rect.minY) / rect.height

        if clamp {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        } else if x < 0 || x > 1 || y < 0 || y > 1 {
            return nil
        }
        return (Float(x), Float(y))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

/// 叠在画面上的状态栏 / 提示 / 触点圆圈；不拦截鼠标事件。
final class HUDView: NSView {
    var statusText = "" {
        didSet { needsDisplay = true }
    }
    var contentRect: CGRect = .zero
    private var touchVisible = false
    private var touchPoint: CGPoint?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setTouch(visible: Bool, at point: CGPoint?) {
        touchVisible = visible
        touchPoint = point
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLetterbox()
        drawStatus()
        drawHint()
        drawTouch()
    }

    private func drawLetterbox() {
        guard contentRect.width > 0, contentRect.width < bounds.width || contentRect.height < bounds.height else {
            return
        }
        NSColor.black.withAlphaComponent(0.55).setFill()
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: contentRect))
        path.windingRule = .evenOdd
        path.fill()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let border = NSBezierPath(rect: contentRect)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawStatus() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: statusText, attributes: attributes)
        let maxWidth = max(bounds.width - 20, 60)
        let measured = text.boundingRect(
            with: NSSize(width: maxWidth - 16, height: 40),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        ).size
        let box = CGRect(
            x: 10,
            y: 10,
            width: min(measured.width + 16, maxWidth),
            height: measured.height + 8
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(
            with: CGRect(x: box.minX + 8, y: box.minY + 4, width: box.width - 16, height: measured.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private func drawHint() {
        let hint = "画面内按下 / 拖动 = 单点触控（id 0）· 框外按下无效"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78)
        ]
        let text = NSAttributedString(string: hint, attributes: attributes)
        let size = text.size()
        let origin = CGPoint(x: 16, y: bounds.height - size.height - 14)

        let box = CGRect(
            x: origin.x - 8,
            y: origin.y - 5,
            width: size.width + 16,
            height: size.height + 10
        )
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin)
    }

    private func drawTouch() {
        guard touchVisible, let point = touchPoint else { return }

        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        ring.lineWidth = 2.5
        ring.stroke()

        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
        NSColor.systemBlue.setFill()
        dot.fill()
    }
}

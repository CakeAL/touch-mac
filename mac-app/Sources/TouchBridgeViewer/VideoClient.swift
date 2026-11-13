import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

/// bridge-rs 视频口（47779）客户端：拆帧 → VideoToolbox 硬解 → 主线程合帧显示。
final class VideoClient {
    struct Stats {
        var state = "未连接"
        var width = 0
        var height = 0
        var fps: Double = 0
        var latencyMs: Double = -1
        var decoded: UInt64 = 0
    }

    private struct Frame {
        let accessUnit: Data
        let key: Bool
    }

    private let host: String
    private let port: UInt16
    private let netQueue = DispatchQueue(label: "touchbridge.video.net", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "touchbridge.video.decode", qos: .userInteractive)

    private var connection: NWConnection?
    private var running = false
    private var rxBytes: [UInt8] = []
    private var reconnect: DispatchWorkItem?

    // MARK: - 解码输入队列（netQueue / decodeQueue 共享，inputLock 保护）

    private let inputLock = NSLock()
    private var pendingFrames: [Frame] = []
    private var pendingFormat: VideoFormat?
    private var needKey = true
    private var decoding = false
    private var stopped = false
    private let maxPending = 3

    // MARK: - 解码器状态（仅 decodeQueue）

    private var session: VTDecompressionSession?
    private var format: VideoFormat?
    private var ptsCounter: Int64 = 0

    // MARK: - 统计（statsLock 保护）

    private let statsLock = NSLock()
    private var stats = Stats()
    private var fpsWindowStart = DispatchTime.now()
    private var fpsWindowFrames = 0
    private var clockOffsetUs: UInt64?
    private var configRaw: Data?
    private var lastKeyframeRequest = DispatchTime(uptimeNanoseconds: 0)

    // MARK: - 显示合帧（displayLock 保护）

    private let displayLock = NSLock()
    private var pendingDisplay: CVImageBuffer?
    private var displayScheduled = false

    var onFrame: ((CVImageBuffer) -> Void)?
    var onStateChange: (() -> Void)?
    /// 解码器需要关键帧时回调（可能来自任意线程）。
    var requestKeyframe: (() -> Void)?

    init(host: String = "127.0.0.1", port: UInt16 = 47779) {
        self.host = host
        self.port = port
    }

    func snapshot() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    // MARK: - 生命周期

    func start() {
        netQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.inputLock.lock()
            self.stopped = false
            self.needKey = true
            self.inputLock.unlock()
            self.connect()
        }
    }

    func stop() {
        netQueue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.reconnect?.cancel()
            self.reconnect = nil
            self.connection?.cancel()
            self.connection = nil

            self.inputLock.lock()
            self.stopped = true
            self.pendingFrames.removeAll()
            self.pendingFormat = nil
            self.needKey = true
            self.inputLock.unlock()

            self.decodeQueue.async {
                if let session = self.session {
                    VTDecompressionSessionWaitForAsynchronousFrames(session)
                    VTDecompressionSessionInvalidate(session)
                }
                self.session = nil
                self.format = nil
            }
        }
    }

    // MARK: - 连接

    private func connect() {
        guard running else { return }
        setState("视频 连接中…")
        let c = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 47779,
            using: .tcp
        )
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.rxBytes.removeAll(keepingCapacity: true)
                self.setState("视频 已连接，等待画面")
                self.receive(on: c)
            case .failed(let error):
                self.setState("视频 断开：\(error.localizedDescription)")
                self.scheduleReconnect(after: c)
            case .cancelled:
                self.scheduleReconnect(after: c)
            case .waiting:
                self.setState("视频 等待网络…")
            default:
                break
            }
        }
        connection = c
        c.start(queue: netQueue)
    }

    private func scheduleReconnect(after c: NWConnection) {
        c.cancel()
        if connection === c {
            connection = nil
        }
        guard running else { return }
        reconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnect = work
        netQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBytes.append(contentsOf: data)
                self.drainMessages()
            }
            if error != nil || isComplete {
                self.scheduleReconnect(after: c)
                return
            }
            self.receive(on: c)
        }
    }

    // MARK: - 拆包

    private func drainMessages() {
        while rxBytes.count >= 5 {
            let type = rxBytes[0]
            let length = (Int(rxBytes[1]) << 24)
                | (Int(rxBytes[2]) << 16)
                | (Int(rxBytes[3]) << 8)
                | Int(rxBytes[4])
            guard length >= 0, length <= 32 << 20 else {
                rxBytes.removeAll()
                setState("视频 数据异常，重连")
                if let c = connection {
                    scheduleReconnect(after: c)
                }
                return
            }
            guard rxBytes.count >= 5 + length else { return }

            let payload = Data(rxBytes[5..<(5 + length)])
            rxBytes.removeFirst(5 + length)

            switch type {
            case 0x01:
                handleConfig(payload)
            case 0x02:
                handleFrame(payload)
            case 0x04:
                handleTick(payload)
            default:
                break // 0x03 音频暂不使用
            }
        }
    }

    // MARK: - 控制消息

    private func handleConfig(_ payload: Data) {
        guard payload != configRaw else { return } // 每个 IDR 会重复携带，忽略
        guard let newFormat = VideoFormat.make(from: payload) else {
            setState("视频 参数集无效")
            return
        }
        configRaw = payload

        inputLock.lock()
        pendingFormat = newFormat
        pendingFrames.removeAll()
        needKey = true
        inputLock.unlock()

        kickDecode()
        requestKeyframeIfNeeded()
        setState("视频 解码器 \(newFormat.dimensions.width)×\(newFormat.dimensions.height)")
    }

    private func handleFrame(_ payload: Data) {
        guard payload.count >= 17 else { return }
        let bytes = [UInt8](payload)
        let key = (bytes[8] & 1) != 0
        let sendUs = beUInt64(bytes, at: 9)
        let accessUnit = payload.subdata(in: 17..<payload.count)
        guard !accessUnit.isEmpty else { return }

        updateLatency(sendUs: sendUs)

        inputLock.lock()
        if needKey && !key {
            inputLock.unlock()
            return
        }
        if pendingFrames.count >= maxPending {
            pendingFrames.removeAll()
            needKey = true
            inputLock.unlock()
            requestKeyframeIfNeeded()
            setState("视频 解码积压，等待关键帧")
            return
        }
        pendingFrames.append(Frame(accessUnit: accessUnit, key: key))
        inputLock.unlock()

        countFrame()
        kickDecode()
    }

    private func handleTick(_ payload: Data) {
        guard payload.count >= 8 else { return }
        let sendUs = beUInt64(payload)
        let now = nowMicroseconds()
        guard now > sendUs else { return }
        let offset = now - sendUs
        if clockOffsetUs == nil || offset < clockOffsetUs! {
            clockOffsetUs = offset
        }
    }

    private func updateLatency(sendUs: UInt64) {
        guard let offset = clockOffsetUs else { return }
        let now = nowMicroseconds()
        let sent = sendUs &+ offset
        guard now > sent else { return }
        let latency = Double(now - sent) / 1000.0
        guard latency < 1000 else { return }
        statsLock.lock()
        if stats.latencyMs < 0 {
            stats.latencyMs = latency
        } else {
            stats.latencyMs = stats.latencyMs * 0.9 + latency * 0.1
        }
        statsLock.unlock()
    }

    private func countFrame() {
        statsLock.lock()
        fpsWindowFrames += 1
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - fpsWindowStart.uptimeNanoseconds) / 1e9
        if elapsed >= 1.0 {
            stats.fps = Double(fpsWindowFrames) / elapsed
            fpsWindowFrames = 0
            fpsWindowStart = DispatchTime.now()
        }
        statsLock.unlock()
    }

    // MARK: - 解码循环

    private func kickDecode() {
        inputLock.lock()
        let shouldStart = !decoding && !stopped && (!pendingFrames.isEmpty || pendingFormat != nil)
        if shouldStart {
            decoding = true
        }
        inputLock.unlock()
        guard shouldStart else { return }
        decodeQueue.async { [weak self] in
            self?.decodeLoop()
        }
    }

    private func decodeLoop() {
        while true {
            inputLock.lock()
            if stopped {
                decoding = false
                pendingFrames.removeAll()
                pendingFormat = nil
                inputLock.unlock()
                return
            }
            let newFormat = pendingFormat
            pendingFormat = nil
            inputLock.unlock()

            if let newFormat {
                setupSession(newFormat)
            }

            inputLock.lock()
            if stopped || pendingFrames.isEmpty {
                decoding = false
                inputLock.unlock()
                return
            }

            var frame: Frame?
            if needKey {
                if let index = pendingFrames.firstIndex(where: { $0.key }) {
                    pendingFrames.removeFirst(index)
                    frame = pendingFrames.removeFirst()
                    needKey = false
                } else {
                    pendingFrames.removeAll()
                }
            } else {
                frame = pendingFrames.removeFirst()
            }
            inputLock.unlock()

            if let frame {
                decode(frame)
            }
        }
    }

    private func setupSession(_ newFormat: VideoFormat) {
        if let old = session {
            VTDecompressionSessionInvalidate(old)
            session = nil
        }
        format = newFormat

        var newSession: VTDecompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat.formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            setState("视频 解码器创建失败 \(status)")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession

        statsLock.lock()
        stats.width = Int(newFormat.dimensions.width)
        stats.height = Int(newFormat.dimensions.height)
        statsLock.unlock()

        setState("视频 \(newFormat.dimensions.width)×\(newFormat.dimensions.height) 解码中")
    }

    private func decode(_ frame: Frame) {
        guard let session, let format else { return }
        ptsCounter += 1
        let pts = CMTime(value: ptsCounter, timescale: 60)
        guard let sampleBuffer = format.makeSampleBuffer(accessUnit: frame.accessUnit, pts: pts, key: frame.key) else {
            return
        }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, imageBuffer, _, _ in
            guard let self else { return }
            if status != noErr || imageBuffer == nil || flags.contains(.frameDropped) {
                self.handleDecodeFailure(status)
                return
            }
            if let imageBuffer {
                self.present(imageBuffer)
            }
        }

        if status != noErr {
            handleDecodeFailure(status)
        }
    }

    /// 解码失败：立即停喂后续帧并等下一个关键帧。保留 session
    /// （重建 session 会打断参考帧队列，且失败风暴里反复重建只会放大问题）。
    private func handleDecodeFailure(_ status: OSStatus) {
        inputLock.lock()
        let wasStopped = stopped
        needKey = true
        pendingFrames.removeAll()
        inputLock.unlock()
        guard !wasStopped else { return }

        setState("视频 解码错误 \(status)，等待关键帧")
        requestKeyframeIfNeeded()
    }

    /// 请求 IDR 做 0.5s 去抖，避免失败循环里把桥打成关键帧风暴。
    private func requestKeyframeIfNeeded() {
        let now = DispatchTime.now()
        inputLock.lock()
        let elapsed = now.uptimeNanoseconds - lastKeyframeRequest.uptimeNanoseconds
        if elapsed >= 500_000_000 {
            lastKeyframeRequest = now
        }
        inputLock.unlock()
        guard elapsed >= 500_000_000 else { return }
        requestKeyframe?()
    }

    // MARK: - 显示

    private func present(_ imageBuffer: CVImageBuffer) {
        displayLock.lock()
        pendingDisplay = imageBuffer
        let shouldSchedule = !displayScheduled
        displayScheduled = true
        displayLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushDisplay()
        }
    }

    private func flushDisplay() {
        displayLock.lock()
        let imageBuffer = pendingDisplay
        pendingDisplay = nil
        displayScheduled = false
        displayLock.unlock()

        guard let imageBuffer else { return }
        statsLock.lock()
        stats.decoded += 1
        let totalFrames = stats.decoded
        let firstFrame = totalFrames == 1
        statsLock.unlock()
        if firstFrame {
            print("[video] 首帧 \(CVPixelBufferGetWidth(imageBuffer))×\(CVPixelBufferGetHeight(imageBuffer))")
        } else if totalFrames % 300 == 0 {
            print("[video] 已解码 \(totalFrames) 帧，画面持续刷新")
        }
        onFrame?(imageBuffer)
    }

    // MARK: - 状态

    private func setState(_ text: String) {
        statsLock.lock()
        let changed = stats.state != text
        stats.state = text
        statsLock.unlock()
        guard changed else { return }
        print("[video] \(text)")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }
}

// MARK: - 工具

private func nowMicroseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1000
}

private func beUInt64(_ bytes: [UInt8], at offset: Int = 0) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value = (value << 8) | UInt64(bytes[offset + i])
    }
    return value
}

private func beUInt64(_ data: Data, at offset: Int = 0) -> UInt64 {
    var value: UInt64 = 0
    let base = data.startIndex + offset
    for i in 0..<8 {
        value = (value << 8) | UInt64(data[base + i])
    }
    return value
}

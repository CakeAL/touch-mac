import Foundation
import Network

/// bridge-rs 触控口（47777）客户端。
///
/// 行协议：`d/m/u <id> <x> <y>`（x/y 归一化 0..1，y 原点左上）、`c` 全抬起、
/// `i` 请求关键帧、`h` 心跳。服务端连接后下发 `#aspect <ratio>`。
final class TouchClient {
    enum Kind: String {
        case down = "d"
        case move = "m"
        case up = "u"
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "touchbridge.touch", qos: .userInteractive)

    private var connection: NWConnection?
    private var rxBytes: [UInt8] = []
    private var running = false
    private var reconnect: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?

    private let lock = NSLock()
    private var _connected = false
    private var _aspect: Float = 0
    private let debugLogging = ProcessInfo.processInfo.environment["TOUCHBRIDGE_SELFTEST"] == "1"

    /// 桥下发的画面宽高比变化时回调（主线程）。
    var onAspectChange: (() -> Void)?
    /// 连接状态变化时回调（主线程）。
    var onStateChange: (() -> Void)?

    init(host: String = "127.0.0.1", port: UInt16 = 47777) {
        self.host = host
        self.port = port
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }

    /// 桥下发的画面宽高比，0 表示尚未收到。
    var aspect: Float {
        lock.lock()
        defer { lock.unlock() }
        return _aspect
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.connect()
            self.startHeartbeat()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.reconnect?.cancel()
            self.reconnect = nil
            self.rawSend("c\n")
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false)
        }
    }

    // MARK: - 对外发送

    func sendTouch(_ kind: Kind, x: Float, y: Float) {
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        let line = String(format: "%@ 0 %.5f %.5f\n", kind.rawValue, nx, ny)
        if debugLogging {
            print("[touch] -> \(line.trimmingCharacters(in: .newlines))")
        }
        queue.async { [weak self] in
            self?.rawSend(line)
        }
    }

    /// 全抬起：失焦、退出、窗口关闭时兜底，避免桥侧残留按下状态。
    func releaseAll() {
        queue.async { [weak self] in
            self?.rawSend("c\n")
        }
    }

    /// 请求一个 IDR，解码器需要重新同步时调用。
    func requestKeyframe() {
        queue.async { [weak self] in
            self?.rawSend("i\n")
        }
    }

    // MARK: - 连接

    private func connect() {
        guard running else { return }
        let c = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 47777,
            using: .tcp
        )
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.rxBytes.removeAll(keepingCapacity: true)
                self.setConnected(true)
                self.receive(on: c)
            case .failed, .cancelled:
                self.setConnected(false)
                self.scheduleReconnect(after: c)
            case .waiting:
                self.setConnected(false)
            default:
                break
            }
        }
        connection = c
        c.start(queue: queue)
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
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBytes.append(contentsOf: data)
                self.parseLines()
            }
            if error != nil || isComplete {
                self.scheduleReconnect(after: c)
                return
            }
            self.receive(on: c)
        }
    }

    private func parseLines() {
        while let newline = rxBytes.firstIndex(of: 0x0A) {
            let lineBytes = Array(rxBytes[..<newline])
            rxBytes.removeFirst(newline + 1)
            guard let raw = String(bytes: lineBytes, encoding: .utf8) else { continue }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#aspect ") {
                let value = line.dropFirst("#aspect ".count).trimmingCharacters(in: .whitespaces)
                if let ratio = Float(value), ratio > 0 {
                    lock.lock()
                    _aspect = ratio
                    lock.unlock()
                    print("[touch] #aspect \(ratio)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onAspectChange?()
                    }
                }
            }
            // #t0 / #hb / #pong 仅用于时钟校准，本客户端不需要。
        }
    }

    // MARK: - 底层

    private func rawSend(_ string: String) {
        guard running, let connection else { return }
        connection.send(content: Data(string.utf8), completion: .contentProcessed { _ in })
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.rawSend("h\n")
        }
        timer.resume()
        heartbeat = timer
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        let changed = _connected != value
        _connected = value
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }
}

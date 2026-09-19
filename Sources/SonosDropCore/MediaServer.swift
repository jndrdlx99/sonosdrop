import Foundation
import Network

public protocol MediaServing: AnyObject {
    var port: UInt16 { get }
    var host: String { get }
    var onAddressChange: (() -> Void)? { get set }
    func start() async throws
    func stop()
    func register(_ fileURL: URL) -> String
    func url(forToken token: String) -> URL?
    func unregisterAll()
}

public enum MediaServerError: Error { case listenerFailed(String), noAddress, stopped }

public final class MediaServer: MediaServing, @unchecked Sendable {
    public var onAddressChange: (() -> Void)?

    private let hostOverride: String?
    private let queue = DispatchQueue(label: "sonosdrop.mediaserver")
    private let filesLock = NSLock()
    private var files: [String: URL] = [:]
    private static let chunkSize = 256 * 1024

    /// Guards every field a listener-restart can race against: `listener`, `_port`, `currentHost`,
    /// `monitor`, and `generation`. `start()`/`stop()` can be called from arbitrary threads, and the
    /// path monitor's restart runs on a detached `Task`, none of which are confined to `queue`.
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var currentHost = ""
    private var _port: UInt16 = 0
    /// Bumped by `start()` and `stop()` only. A restart (`rebindForAddressChange`) captures this
    /// before doing any async work and, once its new listener is ready, only installs it if the
    /// generation is still what it captured — otherwise a `start()`/`stop()` ran meanwhile and the
    /// restart's result is stale, so it's discarded instead of resurrecting/overwriting live state.
    private var generation = 0

    public init(hostOverride: String? = nil) {
        self.hostOverride = hostOverride
    }

    public var port: UInt16 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _port
    }

    public var host: String {
        if let hostOverride { return hostOverride }
        stateLock.lock(); defer { stateLock.unlock() }
        return currentHost
    }

    /// True while a listener is installed. Exposed (internal, test-only) so tests can assert on
    /// final state instead of depending on exact interleaving timing.
    var isListening: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener != nil
    }

    // MARK: lifecycle

    public func start() async throws {
        let ip = LocalIP.primaryIPv4() ?? ""
        if hostOverride == nil && ip.isEmpty { throw MediaServerError.noAddress }

        let myGeneration = nextGeneration()
        let l = try await makeReadyListener()

        guard install(l, ifGenerationIs: myGeneration, host: ip) else {
            l.cancel()
            throw MediaServerError.stopped
        }

        if hostOverride == nil { startMonitor() }
    }

    public func stop() {
        let (l, m) = teardown()
        m?.cancel()
        l?.cancel()
    }

    // MARK: state helpers (synchronous — `NSLock.lock`/`unlock` are unavailable from async contexts,
    // so every touch of `stateLock` is confined to a plain, non-async function like these).

    private func nextGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        generation += 1
        return generation
    }

    private func currentGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    /// Installs `l` as the active listener iff `generation` still equals `expected`, i.e. no
    /// `start()`/`stop()` ran since the caller captured it. Returns whether it installed; on `false`
    /// the caller owns `l` and must cancel it itself.
    private func install(_ l: NWListener, ifGenerationIs expected: Int, host newHost: String, requireExistingListener: Bool = false) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard generation == expected else { return false }
        if requireExistingListener && listener == nil { return false }
        listener?.cancel()
        listener = l
        _port = l.port?.rawValue ?? 0
        currentHost = newHost
        return true
    }

    private func teardown() -> (NWListener?, NWPathMonitor?) {
        stateLock.lock(); defer { stateLock.unlock() }
        generation += 1
        let l = listener, m = monitor
        listener = nil
        monitor = nil
        _port = 0
        return (l, m)
    }

    /// Creates and starts a new listener, suspending until it reports `.ready` (or throwing on
    /// `.failed`). Touches no shared state — callers install the result themselves under `stateLock`
    /// after checking `generation` is still current.
    private func makeReadyListener() async throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Both cases below run serially on `queue`, so this flag is never touched
            // concurrently in practice; `nonisolated(unsafe)` reflects that guarantee to the compiler.
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: MediaServerError.listenerFailed(String(describing: err))) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
        return l
    }

    /// Test-only synchronization seam: if set, called synchronously right after a rebind captures
    /// its generation, before its (real, sometimes sub-millisecond) async listener creation begins.
    /// Lets tests deterministically land a `stop()`/`start()` in the exact window the generation
    /// check exists to guard, instead of racing real OS task scheduling — which is unreliable here
    /// because loopback listener creation can complete faster than a `Task.yield()` resumes.
    var testHook_didCaptureGeneration: (() -> Void)?

    /// Rebinds to `newHost` after the Mac's LAN address changes (sleep/wake, Wi-Fi switch), and
    /// tells the model. If `stop()` (or a fresh `start()`) ran while the new listener was coming up,
    /// this discards it instead of installing it, and does not call `onAddressChange` — the address
    /// change lost the race against an explicit lifecycle change.
    func rebindForAddressChange(newHost: String) async {
        let myGeneration = currentGeneration()
        testHook_didCaptureGeneration?()
        guard let l = try? await makeReadyListener() else { return }
        guard install(l, ifGenerationIs: myGeneration, host: newHost, requireExistingListener: true) else {
            l.cancel()
            return
        }
        onAddressChange?()
    }

    private func startMonitor() {
        // Cancel any previously installed monitor first: startMonitor() can otherwise be called
        // more than once (e.g. a caller invoking start() again on an already-started server)
        // and leak an NWPathMonitor per call, each firing its own rebind.
        let old: NWPathMonitor? = {
            stateLock.lock(); defer { stateLock.unlock() }
            let m = monitor
            monitor = nil
            return m
        }()
        old?.cancel()

        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            let ip = LocalIP.primaryIPv4() ?? ""
            guard !ip.isEmpty else { return }
            let changed: Bool = {
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                return ip != self.currentHost
            }()
            guard changed else { return }
            Task { [weak self] in
                await self?.rebindForAddressChange(newHost: ip)
            }
        }
        m.start(queue: queue)
        stateLock.lock()
        monitor = m
        stateLock.unlock()
    }

    // MARK: registry

    public func register(_ fileURL: URL) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        filesLock.lock(); files[token] = fileURL; filesLock.unlock()
        return token
    }

    public func url(forToken token: String) -> URL? {
        filesLock.lock(); let known = files[token] != nil; filesLock.unlock()
        let p = port, h = host
        guard known, p != 0, !h.isEmpty else { return nil }
        return URL(string: "http://\(h):\(p)/t/\(token)")
    }

    public func unregisterAll() {
        filesLock.lock(); files.removeAll(); filesLock.unlock()
    }

    private func file(forToken token: String) -> URL? {
        filesLock.lock(); defer { filesLock.unlock() }
        return files[token]
    }

    // MARK: connections

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) { self.respond(to: req, on: conn); return }
            if isComplete || error != nil || buf.count > 65536 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(to req: HTTPRequest, on conn: NWConnection) {
        guard req.method == "GET" || req.method == "HEAD", req.path.hasPrefix("/t/"),
              let file = file(forToken: String(req.path.dropFirst(3))),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        else { send(status: "404 Not Found", headers: ["Content-Length": "0"], body: nil, on: conn); return }

        var headers = ["Content-Type": AudioFormat.mime(forExtension: file.pathExtension), "Accept-Ranges": "bytes"]
        let range: Range<Int>
        let status: String
        switch RangeParser.parse(req.headers["range"], fileSize: size) {
        case .unsatisfiable:
            send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"], body: nil, on: conn)
            return
        case .full:
            range = 0..<size; status = "200 OK"
        case .partial(let r):
            range = r; status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(size)"
        }
        headers["Content-Length"] = "\(range.count)"
        let body: (URL, Range<Int>)? = req.method == "HEAD" ? nil : (file, range)
        send(status: status, headers: headers, body: body, on: conn)
    }

    private func send(status: String, headers: [String: String], body: (URL, Range<Int>)?, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\nServer: SonosDrop\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self, let body else {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            guard let fh = try? FileHandle(forReadingFrom: body.0) else { conn.cancel(); return }
            try? fh.seek(toOffset: UInt64(body.1.lowerBound))
            self.stream(fh, remaining: body.1.count, on: conn)
        })
    }

    private func stream(_ fh: FileHandle, remaining: Int, on conn: NWConnection) {
        guard remaining > 0 else {
            try? fh.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let chunk = (try? fh.read(upToCount: min(Self.chunkSize, remaining))) ?? Data()
        guard !chunk.isEmpty else { try? fh.close(); conn.cancel(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? fh.close(); conn.cancel(); return }
            self.stream(fh, remaining: remaining - chunk.count, on: conn)
        })
    }
}

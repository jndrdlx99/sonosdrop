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

public enum MediaServerError: Error { case listenerFailed(String), noAddress }

public final class MediaServer: MediaServing, @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var onAddressChange: (() -> Void)?
    public var host: String { hostOverride ?? currentHost }

    private let hostOverride: String?
    private var currentHost = ""
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "sonosdrop.mediaserver")
    private let lock = NSLock()
    private var files: [String: URL] = [:]
    private static let chunkSize = 256 * 1024

    public init(hostOverride: String? = nil) {
        self.hostOverride = hostOverride
    }

    // MARK: lifecycle

    public func start() async throws {
        currentHost = LocalIP.primaryIPv4() ?? ""
        if hostOverride == nil && currentHost.isEmpty { throw MediaServerError.noAddress }
        try await startListener()
        if hostOverride == nil { startMonitor() }
    }

    public func stop() {
        monitor?.cancel(); monitor = nil
        listener?.cancel(); listener = nil
        port = 0
    }

    private func startListener() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        listener?.cancel()
        listener = l
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Both handlers below run serially on `queue`, so this flag is never touched
            // concurrently in practice; `nonisolated(unsafe)` reflects that guarantee to the compiler.
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: MediaServerError.listenerFailed(String(describing: err))) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
    }

    /// Rebinds when the Mac's LAN address changes (sleep/wake, Wi-Fi switch) and tells the model.
    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            let ip = LocalIP.primaryIPv4() ?? ""
            guard !ip.isEmpty, ip != self.currentHost else { return }
            self.currentHost = ip
            Task { [weak self] in
                guard let self else { return }
                try? await self.startListener()
                self.onAddressChange?()
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    // MARK: registry

    public func register(_ fileURL: URL) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock(); files[token] = fileURL; lock.unlock()
        return token
    }

    public func url(forToken token: String) -> URL? {
        lock.lock(); let known = files[token] != nil; lock.unlock()
        guard known, port != 0, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)/t/\(token)")
    }

    public func unregisterAll() {
        lock.lock(); files.removeAll(); lock.unlock()
    }

    private func file(forToken token: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
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

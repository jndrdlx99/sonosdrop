import Foundation
import Observation

@MainActor
@Observable
public final class QueueModel {
    public var groups: [SpeakerGroup] = []
    public var selectedGroup: SpeakerGroup? {
        didSet { if selectedGroup != oldValue { Task { await self.refreshVolume() } } }
    }
    public var tracks: [Track] = []
    public var nowPlaying: NowPlaying = .idle
    public var volume: Int = 0
    public var serverStatus: String = ""
    public var lastError: String?
    public var needsResend = false
    public var coordinatorReachable = true
    public var isBusy = false
    public var manualIP = ""

    private let client: SonosControlling
    private let discovery: GroupDiscovering
    private let server: MediaServing
    private let inspector: @Sendable (URL) -> Track
    private var pollTask: Task<Void, Never>?
    /// True only once `server.start()` has actually succeeded. Left false on failure so the next
    /// `start()`/`refreshIfStale()` retries the server instead of being permanently locked out
    /// (e.g. the Mac was offline, or the user had not yet answered the Local Network prompt).
    private var serverStarted = false
    /// True once the very first discovery has been kicked off, success or failure. Guards
    /// `start()` against re-running discovery (and its 3 s SSDP search) on every popover open;
    /// later refreshes go through `refreshIfStale`/`refreshGroups` instead.
    private var didInitialDiscovery = false
    private var lastDiscovery: Date?
    /// The in-flight `startServerIfNeeded()` attempt, if any. `start()` (on first launch) and
    /// `refreshIfStale()` (from the popover's `onAppear`) can both call `startServerIfNeeded()`
    /// before either has set `serverStarted`, since the `guard !serverStarted` check and the
    /// first `await` inside `server.start()` are separated by a suspension point a second caller
    /// can land in. Funneling every caller through the same `Task` makes the attempt single-flight
    /// instead of starting the (possibly stateful) server twice concurrently.
    private var serverStartTask: Task<String?, Never>?

    public init(client: SonosControlling, discovery: GroupDiscovering, server: MediaServing,
                inspector: @escaping @Sendable (URL) -> Track = { TrackInspector.inspect($0) }) {
        self.client = client
        self.discovery = discovery
        self.server = server
        self.inspector = inspector
        server.onAddressChange = { [weak self] in
            Task { @MainActor [weak self] in self?.handleAddressChange() }
        }
    }

    /// Called after the media server rebinds to a new LAN address; queued URLs on the speaker are now stale.
    public func handleAddressChange() {
        needsResend = true
        lastError = "Network changed, drop the files again to resend"
        serverStatus = "Serving from \(server.host):\(server.port)"
    }

    // MARK: lifecycle

    public func start() async {
        let serverFailure = await startServerIfNeeded()
        // Discovery's own success/failure handling clears/sets lastError; if the server also
        // failed this call, that message takes priority over whatever discovery left behind.
        defer { if let serverFailure { lastError = serverFailure } }
        guard !didInitialDiscovery else { return }
        didInitialDiscovery = true
        await refreshGroups()
    }

    /// Starts the media server if it has not already succeeded. Safe to call repeatedly, and
    /// safe to call concurrently: a no-op once `serverStarted`; otherwise every caller awaits the
    /// same single in-flight attempt (`serverStartTask`) rather than each starting their own.
    /// Returns the failure message on failure, or nil on success/no-op, so callers can decide
    /// whether it should still apply after other work (like discovery) touches `lastError`.
    @discardableResult
    private func startServerIfNeeded() async -> String? {
        guard !serverStarted else { return nil }
        if let serverStartTask {
            return await serverStartTask.value
        }
        // The whole state mutation below runs inside the task, so it executes exactly once no
        // matter how many callers are awaiting `task.value` — there is only ever one instance of
        // this closure body in flight per attempt.
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            defer { self.serverStartTask = nil }
            do {
                try await self.server.start()
                self.serverStatus = "Serving from \(self.server.host):\(self.server.port)"
                self.serverStarted = true
                self.lastError = nil
                return nil
            } catch {
                let message = "Could not start the file server: \(error)"
                self.lastError = message
                return message
            }
        }
        serverStartTask = task
        return await task.value
    }

    public func refreshGroups() async {
        isBusy = true
        defer { isBusy = false }
        do {
            groups = try await discovery.groups(manualIP: manualIP.isEmpty ? nil : manualIP)
            if let current = selectedGroup, let same = groups.first(where: { $0.id == current.id }) {
                selectedGroup = same
            } else {
                selectedGroup = groups.first
            }
            lastError = nil
            lastDiscovery = Date()
            await refreshVolume()
        } catch {
            // Keep the previous groups/selection: a lost SSDP reply or transient discovery
            // failure should not disable transport mid-playback. Only the initial discovery
            // (groups still empty) leaves the picker showing "No speakers".
            lastError = describe(error)
        }
    }

    /// Re-runs discovery only if the last successful discovery is missing or older than `maxAge`;
    /// also retries the media server if it never successfully started. Called when the popover
    /// opens so a fresh open doesn't always pay for a 3 s SSDP search.
    public func refreshIfStale(maxAge: TimeInterval = 60) async {
        guard !isBusy else { return }
        let serverFailure = await startServerIfNeeded()
        defer { if let serverFailure { lastError = serverFailure } }
        if let lastDiscovery, Date().timeIntervalSince(lastDiscovery) <= maxAge { return }
        await refreshGroups()
    }

    // MARK: drop

    public func drop(_ urls: [URL]) async {
        guard !isBusy else { lastError = "Busy, try the drop again in a moment"; return }
        guard let group = selectedGroup else { lastError = "Pick a speaker first"; return }
        isBusy = true
        defer { isBusy = false }
        needsResend = false
        lastError = nil

        let inspect = inspector
        tracks = await Task.detached { TrackInspector.expand(urls).map(inspect) }.value

        do {
            try await client.clearQueue(group)
            // Only forget the previously served files once the speaker's queue is actually
            // cleared — if clearQueue throws, the old files stay registered and servable.
            server.unregisterAll()
            var queuedAny = false
            for i in tracks.indices where tracks[i].status == .ready {
                let token = server.register(tracks[i].url)
                guard let streamURL = server.url(forToken: token) else {
                    tracks[i].status = .failed("File server has no address")
                    continue
                }
                do {
                    _ = try await client.addToQueue(group, uri: streamURL.absoluteString,
                                                    metadata: DIDL.metadata(track: tracks[i], streamURL: streamURL))
                    tracks[i].status = .queued
                    queuedAny = true
                } catch let e as SonosError where e != .unreachable(group.coordinatorIP) {
                    tracks[i].status = .failed(e.message)
                }
            }
            guard queuedAny else { lastError = "Nothing playable in that drop"; return }
            try await client.playQueue(group)
            coordinatorReachable = true
        } catch {
            lastError = describe(error)
            coordinatorReachable = !(error as? SonosError == .unreachable(group.coordinatorIP))
        }
    }

    // MARK: transport

    public func play() async { await transport { try await self.client.play($0) } }
    public func pause() async { await transport { try await self.client.pause($0) } }
    public func next() async { await transport { try await self.client.next($0) } }
    public func previous() async { await transport { try await self.client.previous($0) } }

    public func setVolume(_ v: Int) async {
        volume = v
        await transport { try await self.client.setVolume($0, v) }
    }

    private func transport(_ op: @escaping (SpeakerGroup) async throws -> Void) async {
        guard let group = selectedGroup else { return }
        do {
            try await op(group)
            coordinatorReachable = true
        } catch {
            lastError = describe(error)
            if case .unreachable = error as? SonosError { coordinatorReachable = false }
        }
    }

    private func refreshVolume() async {
        guard let group = selectedGroup else { return }
        if let v = try? await client.volume(group) { volume = v }
    }

    // MARK: polling

    public func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func pollOnce() async {
        guard let group = selectedGroup else { return }
        do {
            let np = try await client.positionInfo(group)
            nowPlaying = np
            coordinatorReachable = true
            var queuedIndex = 0
            for i in tracks.indices where tracks[i].status == .queued || tracks[i].status == .playing {
                queuedIndex += 1
                tracks[i].status = (queuedIndex == np.trackNumber && np.state == .playing) ? .playing : .queued
            }
        } catch {
            if case .unreachable = error as? SonosError { coordinatorReachable = false }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? SonosError)?.message ?? String(describing: error)
    }
}

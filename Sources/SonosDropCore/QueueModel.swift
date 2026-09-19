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
        do {
            try await server.start()
            serverStatus = "Serving from \(server.host):\(server.port)"
        } catch {
            lastError = "Could not start the file server: \(error)"
        }
        await refreshGroups()
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
            await refreshVolume()
        } catch {
            groups = []
            selectedGroup = nil
            lastError = describe(error)
        }
    }

    // MARK: drop

    public func drop(_ urls: [URL]) async {
        guard let group = selectedGroup else { lastError = "Pick a speaker first"; return }
        isBusy = true
        defer { isBusy = false }
        needsResend = false
        lastError = nil

        let inspect = inspector
        tracks = await Task.detached { TrackInspector.expand(urls).map(inspect) }.value
        server.unregisterAll()

        do {
            try await client.clearQueue(group)
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

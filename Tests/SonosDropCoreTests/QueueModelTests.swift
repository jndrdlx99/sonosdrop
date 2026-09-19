import Testing
import Foundation
@testable import SonosDropCore

final class FakeClient: SonosControlling, @unchecked Sendable {
    var calls: [String] = []
    var rejectURIsContaining: String? = nil
    var position = NowPlaying(title: "Now", artist: "Someone", elapsed: 10, duration: 100, state: .playing, trackNumber: 1)
    var currentVolume = 25

    func clearQueue(_ g: SpeakerGroup) async throws { calls.append("clear") }
    func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int {
        if let bad = rejectURIsContaining, uri.contains(bad) { throw SonosError.upnp(714) }
        calls.append("add \(uri)")
        return calls.count
    }
    func playQueue(_ g: SpeakerGroup) async throws { calls.append("playQueue") }
    func play(_ g: SpeakerGroup) async throws { calls.append("play") }
    func pause(_ g: SpeakerGroup) async throws { calls.append("pause") }
    func next(_ g: SpeakerGroup) async throws { calls.append("next") }
    func previous(_ g: SpeakerGroup) async throws { calls.append("previous") }
    func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying { position }
    func volume(_ g: SpeakerGroup) async throws -> Int { currentVolume }
    func setVolume(_ g: SpeakerGroup, _ value: Int) async throws { currentVolume = value; calls.append("volume \(value)") }
    func zoneGroupStateXML(ip: String) async throws -> String { "" }
}

struct FakeServerStartError: Error {}

final class FakeServer: MediaServing, @unchecked Sendable {
    var port: UInt16 = 5000
    var host = "10.0.0.9"
    var onAddressChange: (() -> Void)?
    var tokens: [String: URL] = [:]
    var started = false
    var startCount = 0
    /// When true, the next `start()` throws instead of succeeding (and does not set `started`).
    var failNextStart = false
    private var counter = 0
    func start() async throws {
        startCount += 1
        guard !failNextStart else { throw FakeServerStartError() }
        started = true
    }
    func stop() { started = false }
    func register(_ fileURL: URL) -> String { counter += 1; let t = "tok\(counter)"; tokens[t] = fileURL; return t }
    func url(forToken token: String) -> URL? { tokens[token] == nil ? nil : URL(string: "http://\(host):\(port)/t/\(token)") }
    func unregisterAll() { tokens.removeAll() }
}

/// A class (not a struct) so tests can mutate `result` between calls, e.g. to simulate a
/// discovery request that starts succeeding and later starts failing.
final class FakeDiscovery: GroupDiscovering, @unchecked Sendable {
    var result: Result<[SpeakerGroup], SonosError>
    var calls = 0
    init(result: Result<[SpeakerGroup], SonosError>) { self.result = result }
    func groups(manualIP: String?) async throws -> [SpeakerGroup] { calls += 1; return try result.get() }
}

let studioGroup = SpeakerGroup(coordinatorUUID: "RINCON_1", coordinatorIP: "10.0.0.2", name: "Studio", memberIPs: ["10.0.0.2"])

/// Inspector stub: anything named "hires" is unsupported, everything else is CD-quality FLAC.
@Sendable func fakeInspect(_ url: URL) -> Track {
    if url.lastPathComponent.contains("hires") {
        return Track(url: url, sampleRate: 96000, bitDepth: 24, codec: "FLAC", status: .unsupported("96 kHz, Sonos max is 48"))
    }
    return Track(url: url, title: url.deletingPathExtension().lastPathComponent, artist: "A", duration: 60, sampleRate: 44100, bitDepth: 16, codec: "FLAC")
}

@MainActor private func makeModel(client: FakeClient = FakeClient(), server: FakeServer = FakeServer(),
                                  discovery: FakeDiscovery = FakeDiscovery(result: .success([studioGroup]))) -> QueueModel {
    QueueModel(client: client, discovery: discovery, server: server, inspector: fakeInspect)
}

@MainActor @Test func startBringsUpServerAndSelectsFirstGroup() async {
    let server = FakeServer()
    let model = makeModel(server: server)
    await model.start()
    #expect(server.started)
    #expect(model.selectedGroup == studioGroup)
    #expect(model.serverStatus == "Serving from 10.0.0.9:5000")
    #expect(model.volume == 25)
}

@MainActor @Test func startWithNoSpeakersShowsError() async {
    let model = makeModel(discovery: FakeDiscovery(result: .failure(.noSpeakers)))
    await model.start()
    #expect(model.groups.isEmpty)
    #expect(model.lastError == "No Sonos speakers found")
}

@MainActor @Test func dropQueuesPlayableTracksInOrderAndSkipsUnsupported() async {
    let client = FakeClient()
    let server = FakeServer()
    let model = makeModel(client: client, server: server)
    await model.start()
    let urls = [URL(fileURLWithPath: "/m/01 a.flac"), URL(fileURLWithPath: "/m/02 hires.flac"), URL(fileURLWithPath: "/m/03 c.flac")]
    await model.drop(urls)
    #expect(client.calls == ["clear", "add http://10.0.0.9:5000/t/tok1", "add http://10.0.0.9:5000/t/tok2", "playQueue"])
    #expect(model.tracks.map(\.status) == [.queued, .unsupported("96 kHz, Sonos max is 48"), .queued])
    #expect(server.tokens.count == 2)
    #expect(model.lastError == nil)
}

@MainActor @Test func dropWithNothingPlayableDoesNotTouchTransport() async {
    let client = FakeClient()
    let model = makeModel(client: client)
    await model.start()
    await model.drop([URL(fileURLWithPath: "/m/hires.flac")])
    #expect(client.calls == ["clear"])
    #expect(model.lastError == "Nothing playable in that drop")
}

@MainActor @Test func rejectedTrackIsMarkedFailedAndOthersContinue() async {
    let client = FakeClient()
    client.rejectURIsContaining = "tok1"
    let model = makeModel(client: client)
    await model.start()
    await model.drop([URL(fileURLWithPath: "/m/a.flac"), URL(fileURLWithPath: "/m/b.flac")])
    #expect(model.tracks[0].status == .failed("Sonos rejected the request (UPnP 714)"))
    #expect(model.tracks[1].status == .queued)
    #expect(client.calls.last == "playQueue")
}

@MainActor @Test func dropWithoutSpeakerIsAnError() async {
    let model = makeModel(discovery: FakeDiscovery(result: .failure(.noSpeakers)))
    await model.start()
    await model.drop([URL(fileURLWithPath: "/m/a.flac")])
    #expect(model.lastError == "Pick a speaker first")
    #expect(model.tracks.isEmpty)
}

@MainActor @Test func transportAndVolumeForwardToClient() async {
    let client = FakeClient()
    let model = makeModel(client: client)
    await model.start()
    await model.play(); await model.pause(); await model.next(); await model.previous(); await model.setVolume(40)
    #expect(client.calls == ["play", "pause", "next", "previous", "volume 40"])
    #expect(model.volume == 40)
}

@MainActor @Test func pollUpdatesNowPlayingAndMarksPlayingTrack() async {
    let client = FakeClient()
    let model = makeModel(client: client)
    await model.start()
    await model.drop([URL(fileURLWithPath: "/m/a.flac"), URL(fileURLWithPath: "/m/b.flac")])
    client.position.trackNumber = 2
    await model.pollOnce()
    #expect(model.nowPlaying.title == "Now")
    #expect(model.tracks.map(\.status) == [.queued, .playing])
    #expect(model.coordinatorReachable)
}

@MainActor @Test func addressChangeFlagsResend() async {
    let server = FakeServer()
    let model = makeModel(server: server)
    await model.start()
    model.handleAddressChange()
    #expect(model.needsResend)
    #expect(model.lastError == "Network changed, drop the files again to resend")
}

@MainActor @Test func dropExpandsFolderOffMainActor() async throws {
    let client = FakeClient()
    let model = makeModel(client: client)
    await model.start()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    FileManager.default.createFile(atPath: dir.appendingPathComponent("b.flac").path, contents: nil)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("a.mp3").path, contents: nil)
    await model.drop([dir])
    #expect(model.tracks.map { $0.url.lastPathComponent } == ["a.mp3", "b.flac"])
}

@MainActor @Test func startTwiceStartsServerOnce() async {
    let server = FakeServer()
    let model = makeModel(server: server)
    await model.start()
    await model.start()
    #expect(server.startCount == 1)
}

@MainActor @Test func failedServerStartIsRetried() async {
    let server = FakeServer()
    server.failNextStart = true
    let model = makeModel(server: server)

    await model.start()
    #expect(model.lastError?.contains("Could not start the file server") == true)
    #expect(server.startCount == 1)

    server.failNextStart = false
    await model.start()
    #expect(server.startCount == 2)
    #expect(model.serverStatus == "Serving from 10.0.0.9:5000")
    #expect(model.lastError == nil)
}

@MainActor @Test func refreshFailureKeepsPreviousSelection() async {
    let discovery = FakeDiscovery(result: .success([studioGroup]))
    let model = makeModel(discovery: discovery)
    await model.start()
    #expect(model.selectedGroup == studioGroup)

    discovery.result = .failure(.noSpeakers)
    await model.refreshGroups()

    #expect(model.selectedGroup == studioGroup)
    #expect(model.lastError == "No Sonos speakers found")
}

@MainActor @Test func refreshIfStaleSkipsWhenFresh() async {
    let discovery = FakeDiscovery(result: .success([studioGroup]))
    let model = makeModel(discovery: discovery)
    await model.start()
    #expect(discovery.calls == 1)

    await model.refreshIfStale()
    #expect(discovery.calls == 1)

    await model.refreshIfStale(maxAge: 0)
    #expect(discovery.calls == 2)
}

import Foundation

public protocol SonosControlling: Sendable {
    func clearQueue(_ g: SpeakerGroup) async throws
    func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int
    func playQueue(_ g: SpeakerGroup) async throws
    func play(_ g: SpeakerGroup) async throws
    func pause(_ g: SpeakerGroup) async throws
    func next(_ g: SpeakerGroup) async throws
    func previous(_ g: SpeakerGroup) async throws
    func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying
    func volume(_ g: SpeakerGroup) async throws -> Int
    func setVolume(_ g: SpeakerGroup, _ value: Int) async throws
    func zoneGroupStateXML(ip: String) async throws -> String
}

public final class SonosClient: SonosControlling, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func invoke(ip: String, service: SonosService, action: String, args: [(String, String)]) async throws -> [String: String] {
        var req = URLRequest(url: URL(string: "http://\(ip):1400\(service.controlPath)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(SOAP.envelope(service: service, action: action, args: args).utf8)
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw SonosError.unreachable(ip) }
        let values = try SOAP.parseResponse(data)   // throws .upnp(code) on faults, even with HTTP 500
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SonosError.http(status) }
        return values
    }

    // MARK: helpers

    private func av(_ g: SpeakerGroup, _ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        try await invoke(ip: g.coordinatorIP, service: .avTransport, action: action, args: [("InstanceID", "0")] + args)
    }

    // MARK: SonosControlling

    public func clearQueue(_ g: SpeakerGroup) async throws {
        _ = try await av(g, "RemoveAllTracksFromQueue")
    }

    public func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int {
        let r = try await av(g, "AddURIToQueue", [("EnqueuedURI", uri), ("EnqueuedURIMetaData", metadata),
                                                  ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0")])
        return Int(r["FirstTrackNumberEnqueued"] ?? "") ?? 0
    }

    public func playQueue(_ g: SpeakerGroup) async throws {
        _ = try await av(g, "SetAVTransportURI", [("CurrentURI", g.queueURI), ("CurrentURIMetaData", "")])
        _ = try await av(g, "Seek", [("Unit", "TRACK_NR"), ("Target", "1")])
        try await play(g)
    }

    public func play(_ g: SpeakerGroup) async throws { _ = try await av(g, "Play", [("Speed", "1")]) }
    public func pause(_ g: SpeakerGroup) async throws { _ = try await av(g, "Pause") }
    public func next(_ g: SpeakerGroup) async throws { _ = try await av(g, "Next") }
    public func previous(_ g: SpeakerGroup) async throws { _ = try await av(g, "Previous") }

    public func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying {
        let pos = try await av(g, "GetPositionInfo")
        let transport = try await av(g, "GetTransportInfo")
        let meta = DIDL.titleArtist(from: pos["TrackMetaData"] ?? "")
        return NowPlaying(title: meta.title,
                          artist: meta.artist,
                          elapsed: TimeFormat.seconds(pos["RelTime"] ?? ""),
                          duration: TimeFormat.seconds(pos["TrackDuration"] ?? ""),
                          state: TransportState(rawValue: transport["CurrentTransportState"] ?? "") ?? .unknown,
                          trackNumber: Int(pos["Track"] ?? "") ?? 0)
    }

    public func volume(_ g: SpeakerGroup) async throws -> Int {
        let r = try await invoke(ip: g.coordinatorIP, service: .groupRenderingControl, action: "GetGroupVolume", args: [("InstanceID", "0")])
        return Int(r["CurrentVolume"] ?? "") ?? 0
    }

    public func setVolume(_ g: SpeakerGroup, _ value: Int) async throws {
        let v = min(100, max(0, value))
        _ = try await invoke(ip: g.coordinatorIP, service: .groupRenderingControl, action: "SetGroupVolume", args: [("InstanceID", "0"), ("DesiredVolume", "\(v)")])
    }

    public func zoneGroupStateXML(ip: String) async throws -> String {
        let r = try await invoke(ip: ip, service: .zoneGroupTopology, action: "GetZoneGroupState", args: [])
        guard let xml = r["ZoneGroupState"], !xml.isEmpty else { throw SonosError.badResponse("no ZoneGroupState") }
        return xml
    }
}

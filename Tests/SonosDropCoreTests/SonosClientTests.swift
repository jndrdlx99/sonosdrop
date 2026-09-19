import Testing
import Foundation
@testable import SonosDropCore

/// Captures the last request and returns a canned body.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var responseBody = ""
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "text/xml"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubClient() -> SonosClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return SonosClient(session: URLSession(configuration: cfg))
}

private let studio = SpeakerGroup(coordinatorUUID: "RINCON_A1B2C300000001400", coordinatorIP: "192.168.1.52", name: "Studio", memberIPs: ["192.168.1.52", "192.168.1.56"])

private func response(_ action: String, _ inner: String) -> String {
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>"
}

// StubProtocol.lastRequest/.responseBody/.status are shared mutable statics; .serialized
// keeps these tests from interleaving under Swift Testing's default parallel execution,
// which otherwise lets one test's stubbed response leak into another's assertions.
@Suite(.serialized)
struct SonosClientTests {
    @Test func addToQueueTargetsCoordinatorWithSoapHeaders() async throws {
        StubProtocol.status = 200
        StubProtocol.responseBody = response("AddURIToQueue", "<FirstTrackNumberEnqueued>3</FirstTrackNumberEnqueued><NumTracksAdded>1</NumTracksAdded><NewQueueLength>3</NewQueueLength>")
        let n = try await stubClient().addToQueue(studio, uri: "http://192.168.1.66:5000/t/abc", metadata: "<DIDL-Lite/>")
        #expect(n == 3)
        let req = StubProtocol.lastRequest!
        #expect(req.url?.absoluteString == "http://192.168.1.52:1400/MediaRenderer/AVTransport/Control")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "SOAPACTION") == "\"urn:schemas-upnp-org:service:AVTransport:1#AddURIToQueue\"")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "text/xml; charset=\"utf-8\"")
    }

    @Test func positionInfoParsesMetadataAndTimes() async throws {
        StubProtocol.status = 200
        // The client calls GetPositionInfo then GetTransportInfo; the stub returns the same body for both, which carries both sets of leaves.
        StubProtocol.responseBody = response("GetPositionInfo",
            "<Track>5</Track><TrackDuration>0:05:45</TrackDuration><TrackMetaData>&lt;DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"&gt;&lt;item&gt;&lt;dc:title&gt;Self Care&lt;/dc:title&gt;&lt;dc:creator&gt;Mac Miller&lt;/dc:creator&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><RelTime>0:01:24</RelTime><CurrentTransportState>PLAYING</CurrentTransportState>")
        let np = try await stubClient().positionInfo(studio)
        #expect(np.title == "Self Care")
        #expect(np.artist == "Mac Miller")
        #expect(np.elapsed == 84)
        #expect(np.duration == 345)
        #expect(np.trackNumber == 5)
        #expect(np.state == .playing)
    }

    @Test func upnpFaultSurfacesAsError() async {
        StubProtocol.status = 500
        StubProtocol.responseBody = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
        await #expect(throws: SonosError.upnp(701)) { try await stubClient().play(studio) }
    }

    @Test func invalidManualURLThrowsUnreachableInsteadOfCrashing() async {
        // A manual IP with an embedded space (e.g. a copy/paste mistake) makes
        // "http://<ip>:1400<path>" an invalid URL string; invoke() must surface that as
        // .unreachable instead of force-unwrapping and crashing.
        await #expect(throws: SonosError.unreachable("10.20 .28.52")) {
            _ = try await stubClient().invoke(ip: "10.20 .28.52", service: .avTransport, action: "Play", args: [])
        }
    }

    @Test func unreachableHostIsMapped() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        let client = SonosClient(session: URLSession(configuration: cfg))
        let dead = SpeakerGroup(coordinatorUUID: "X", coordinatorIP: "10.255.255.1", name: "Dead", memberIPs: [])
        await #expect(throws: SonosError.unreachable("10.255.255.1")) { try await client.pause(dead) }
    }
}

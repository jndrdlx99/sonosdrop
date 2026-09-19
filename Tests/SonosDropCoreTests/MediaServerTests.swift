import Testing
import Foundation
@testable import SonosDropCore

private func fixture(_ name: String, _ ext: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
}

private func request(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    if let range { req.setValue(range, forHTTPHeaderField: "Range") }
    let (data, resp) = try await URLSession.shared.data(for: req)
    return (data, resp as! HTTPURLResponse)
}

@Test func servesWholeFileWithHeaders() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let file = fixture("tone_16_44100", "flac")
    let token = server.register(file)
    let url = server.url(forToken: token)!
    #expect(url.absoluteString == "http://127.0.0.1:\(server.port)/t/\(token)")
    let (data, resp) = try await request(url)
    #expect(resp.statusCode == 200)
    #expect(resp.value(forHTTPHeaderField: "Content-Type") == "audio/flac")
    #expect(resp.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(data == (try Data(contentsOf: file)))
}

@Test func servesByteRange() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let file = fixture("tone_16_44100", "flac")
    let whole = try Data(contentsOf: file)
    let url = server.url(forToken: server.register(file))!
    let (data, resp) = try await request(url, range: "bytes=100-199")
    #expect(resp.statusCode == 206)
    #expect(resp.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/\(whole.count)")
    #expect(data == whole[100..<200])
}

@Test func headHasNoBody() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let file = fixture("tone_aac", "m4a")
    let url = server.url(forToken: server.register(file))!
    let (data, resp) = try await request(url, method: "HEAD")
    #expect(resp.statusCode == 200)
    #expect(data.isEmpty)
    #expect(resp.value(forHTTPHeaderField: "Content-Length") == "\(try Data(contentsOf: file).count)")
}

@Test func unknownTokenAndUnsatisfiableRange() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let (_, notFound) = try await request(URL(string: "http://127.0.0.1:\(server.port)/t/nope")!)
    #expect(notFound.statusCode == 404)
    let (_, root) = try await request(URL(string: "http://127.0.0.1:\(server.port)/")!)
    #expect(root.statusCode == 404)
    let url = server.url(forToken: server.register(fixture("tone_aac", "m4a")))!
    let (_, bad) = try await request(url, range: "bytes=999999-")
    #expect(bad.statusCode == 416)
}

@Test func unregisterAllForgetsTokens() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let url = server.url(forToken: server.register(fixture("tone_aac", "m4a")))!
    server.unregisterAll()
    let (_, resp) = try await request(url)
    #expect(resp.statusCode == 404)
}

@Test func primaryIPv4LooksLikeAnAddress() {
    let ip = LocalIP.primaryIPv4()
    #expect(ip != nil)
    #expect(ip?.split(separator: ".").count == 4)
    #expect(ip != "127.0.0.1")
}

@Test func restartAfterStopServesAgain() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    let token1 = server.register(fixture("tone_aac", "m4a"))
    let url1 = server.url(forToken: token1)!
    let (_, resp1) = try await request(url1)
    #expect(resp1.statusCode == 200)

    server.stop()
    try await server.start()
    defer { server.stop() }

    let token2 = server.register(fixture("tone_aac", "m4a"))
    let url2 = server.url(forToken: token2)!
    let (_, resp2) = try await request(url2)
    #expect(resp2.statusCode == 200)
}

@Test func rebindDiscardedWhenStoppedMidFlight() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }
    let token = server.register(fixture("tone_aac", "m4a"))
    let oldURL = server.url(forToken: token)!

    nonisolated(unsafe) var notified = false
    server.onAddressChange = { notified = true }
    // Deterministically land stop() in the window between the rebind capturing its generation and
    // installing its new listener — the exact race the generation check exists to resolve. A real
    // OS-scheduling race here (Task + Task.yield()) was empirically flaky: loopback listener
    // creation can complete in well under a millisecond, sometimes faster than the yield resumes,
    // so the rebind occasionally finished (and fired onAddressChange) before stop() got a chance to
    // run at all.
    server.testHook_didCaptureGeneration = { server.stop() }

    await server.rebindForAddressChange(newHost: "127.0.0.1")

    #expect(server.isListening == false)
    #expect(server.port == 0)
    #expect(notified == false)
    do {
        _ = try await request(oldURL)
        Issue.record("expected a request to the stopped server's old address to fail")
    } catch {
        // expected: stop() tore down the listener the request was aimed at.
    }
}

@Test func rebindInstallsNewListenerAndNotifies() async throws {
    let server = MediaServer(hostOverride: "127.0.0.1")
    try await server.start()
    defer { server.stop() }

    nonisolated(unsafe) var notifyCount = 0
    server.onAddressChange = { notifyCount += 1 }

    await server.rebindForAddressChange(newHost: "127.0.0.1")
    #expect(notifyCount == 1)

    let token = server.register(fixture("tone_aac", "m4a"))
    let url = server.url(forToken: token)!
    let (_, resp) = try await request(url)
    #expect(resp.statusCode == 200)
}

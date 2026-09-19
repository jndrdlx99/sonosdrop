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

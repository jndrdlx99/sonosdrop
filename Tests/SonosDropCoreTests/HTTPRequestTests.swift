import Testing
import Foundation
@testable import SonosDropCore

@Test func parsesRequestLineAndLowercasesHeaders() {
    let raw = "GET /t/abc?x=1 HTTP/1.1\r\nHost: 10.0.0.5:8080\r\nRange: bytes=0-\r\nUser-Agent: Linux UPnP/1.0 Sonos/97.1-80312\r\n\r\n"
    let req = HTTPRequest.parse(Data(raw.utf8))
    #expect(req?.method == "GET")
    #expect(req?.path == "/t/abc")
    #expect(req?.headers["range"] == "bytes=0-")
    #expect(req?.headers["host"] == "10.0.0.5:8080")
}

@Test func incompleteRequestReturnsNil() {
    #expect(HTTPRequest.parse(Data("GET /t/abc HTTP/1.1\r\nHost: x".utf8)) == nil)
}

@Test func rangeParsing() {
    #expect(RangeParser.parse(nil, fileSize: 1000) == .full)
    #expect(RangeParser.parse("bytes=0-", fileSize: 1000) == .partial(0..<1000))
    #expect(RangeParser.parse("bytes=100-199", fileSize: 1000) == .partial(100..<200))
    #expect(RangeParser.parse("bytes=900-5000", fileSize: 1000) == .partial(900..<1000))
    #expect(RangeParser.parse("bytes=-100", fileSize: 1000) == .partial(900..<1000))
    #expect(RangeParser.parse("bytes=1000-", fileSize: 1000) == .unsatisfiable)
    #expect(RangeParser.parse("bytes=5-2", fileSize: 1000) == .unsatisfiable)
    #expect(RangeParser.parse("items=0-1", fileSize: 1000) == .full)
    #expect(RangeParser.parse("bytes=0-99,200-299", fileSize: 1000) == .partial(0..<100))
}

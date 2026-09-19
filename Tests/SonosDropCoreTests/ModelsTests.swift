import Testing
import Foundation
@testable import SonosDropCore

@Test func formatBadgeShowsBitsForLossless() {
    let t = Track(url: URL(fileURLWithPath: "/x.flac"), sampleRate: 44100, bitDepth: 16, codec: "FLAC")
    #expect(t.formatBadge == "FLAC 16/44.1")
}

@Test func formatBadgeOmitsBitsForLossy() {
    let t = Track(url: URL(fileURLWithPath: "/x.m4a"), sampleRate: 48000, bitDepth: 16, codec: "AAC")
    #expect(t.formatBadge == "AAC 48")
}

@Test func titleFallsBackToFileName() {
    let t = Track(url: URL(fileURLWithPath: "/Music/Moscow Mule.flac"))
    #expect(t.title == "Moscow Mule")
}

@Test func timeFormatRoundTrips() {
    #expect(TimeFormat.hms(245.94) == "0:04:06")
    #expect(TimeFormat.seconds("0:04:05") == 245)
    #expect(TimeFormat.seconds("NOT_IMPLEMENTED") == 0)
}

@Test func mimeTypes() {
    #expect(AudioFormat.mime(forExtension: "FLAC") == "audio/flac")
    #expect(AudioFormat.mime(forExtension: "m4a") == "audio/mp4")
    #expect(AudioFormat.mime(forExtension: "xyz") == "application/octet-stream")
}

@Test func queueURI() {
    let g = SpeakerGroup(coordinatorUUID: "RINCON_1", coordinatorIP: "10.0.0.2", name: "Studio", memberIPs: ["10.0.0.2"])
    #expect(g.queueURI == "x-rincon-queue:RINCON_1#0")
}

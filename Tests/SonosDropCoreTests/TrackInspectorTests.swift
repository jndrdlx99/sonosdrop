import Testing
import Foundation
@testable import SonosDropCore

private func fixture(_ name: String, _ ext: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
}

@Test func cdQualityFlacIsReady() {
    let t = TrackInspector.inspect(fixture("tone_16_44100", "flac"))
    #expect(t.status == .ready)
    #expect(t.codec == "FLAC")
    #expect(t.sampleRate == 44100)
    #expect(t.bitDepth == 16)
    #expect(t.channels == 2)
    #expect(t.formatBadge == "FLAC 16/44.1")
    #expect(abs(t.duration - 1.0) < 0.1)
    #expect(t.title == "tone_16_44100")
}

@Test func hiResFlacIsUnsupportedWithReason() {
    let t = TrackInspector.inspect(fixture("tone_24_96000", "flac"))
    #expect(t.status == .unsupported("96 kHz, Sonos max is 48"))
    #expect(t.formatBadge == "FLAC 24/96")
}

@Test func aacIsReadyWithoutBitDepthInBadge() {
    let t = TrackInspector.inspect(fixture("tone_aac", "m4a"))
    #expect(t.status == .ready)
    #expect(t.codec == "AAC")
    #expect(t.formatBadge == "AAC 44.1")
}

@Test func unknownExtensionIsUnsupported() {
    let t = TrackInspector.inspect(URL(fileURLWithPath: "/tmp/notes.txt"))
    #expect(t.status == .unsupported("Format .txt not supported by Sonos"))
}

@Test func unreadableFileIsUnsupported() {
    let t = TrackInspector.inspect(URL(fileURLWithPath: "/tmp/does-not-exist.flac"))
    #expect(t.status == .unsupported("Can't read file"))
}

@Test func expandWalksFoldersOneLevelSorted() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonosdrop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["b.flac", "a.mp3", ".hidden.flac", "cover.jpg"] {
        try Data().write(to: dir.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("sub/deep.flac"))
    let loose = dir.appendingPathComponent("cover.jpg")
    let result = TrackInspector.expand([dir, loose])
    #expect(result.map(\.lastPathComponent) == ["a.mp3", "b.flac", "cover.jpg"])
}

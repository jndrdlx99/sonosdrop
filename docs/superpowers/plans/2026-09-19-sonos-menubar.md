# SonosDrop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that serves dropped audio files from the Mac and queues them on a chosen Sonos group.

**Architecture:** Swift package with a `SonosDropCore` library (discovery, SOAP client, HTTP media server, track inspection, observable model) and a thin `SonosDrop` SwiftUI executable (`MenuBarExtra`). The speaker pulls files over HTTP from the Mac and advances its own queue; the app only keeps the server alive and polls position.

**Tech Stack:** Swift 6.4 Command Line Tools (no Xcode), Swift Package Manager, Swift Testing (`import Testing`, XCTest is NOT available without Xcode), Foundation, Network.framework, AudioToolbox, SwiftUI/Observation. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-09-19-sonos-menubar-design.md`

## Global Constraints

- Toolchain: `/Library/Developer/CommandLineTools`, Swift 6.4, macOS 27. Package `platforms: [.macOS(.v15)]`, every target `swiftSettings: [.swiftLanguageMode(.v5)]`.
- Tests use `import Testing` with `@Test` / `#expect`. Never `import XCTest`.
- Zero dependencies: only Foundation, Network, AudioToolbox, Observation, SwiftUI, Darwin.
- Sonos limits: formats MP3, AAC (m4a/mp4/aac), FLAC, ALAC, WAV, AIFF, OGG; max 24-bit / 48 kHz; max 2 channels.
- All group commands go to the coordinator IP from topology, never a stereo-pair secondary.
- Media server serves only registered tokens under `/t/<token>`, supports `Range`, sends `Content-Length`, `Content-Type`, `Accept-Ranges: bytes`, `Connection: close`.
- Bundle id `com.jndrdlx.sonosdrop`, `LSUIElement=true`, ad-hoc signed (`codesign --sign -`).
- Commit after every task with the attribution trailer:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK
  ```

## File structure

```
Package.swift
Makefile
.gitignore
scripts/make-fixtures.sh              generates 1 s test tones with python3 + afconvert
scripts/bundle.sh                     release build -> build/SonosDrop.app -> /Applications
Sources/SonosDropCore/
  Models.swift        Track, TrackStatus, SpeakerGroup, NowPlaying, TransportState, AudioFormat, TimeFormat
  DIDL.swift          XML.escape, DIDL.metadata, DIDL.titleArtist
  HTTPRequest.swift   HTTPRequest.parse, RangeParser
  LocalIP.swift       LocalIP.primaryIPv4()
  MediaServer.swift   MediaServing protocol, MediaServer (NWListener)
  TrackInspector.swift
  SOAP.swift          SonosService, SonosError, SOAP.envelope, SOAP.parseResponse, XMLLeaves
  SonosClient.swift   SonosControlling protocol, SonosClient
  Topology.swift      TopologyParser, SSDP
  Discovery.swift     GroupDiscovering protocol, Discovery
  QueueModel.swift    @Observable QueueModel
Sources/SonosDrop/
  SonosDropApp.swift
  MenuBarView.swift
Tests/SonosDropCoreTests/
  Fixtures/tone_16_44100.flac, tone_24_96000.flac, tone_aac.m4a
  ModelsTests.swift DIDLTests.swift HTTPRequestTests.swift MediaServerTests.swift
  TrackInspectorTests.swift SOAPTests.swift TopologyTests.swift SonosClientTests.swift QueueModelTests.swift
```

---

### Task 1: Package scaffold, models, fixtures

**Files:**
- Create: `Package.swift`, `Makefile`, `.gitignore`, `scripts/make-fixtures.sh`
- Create: `Sources/SonosDropCore/Models.swift`
- Create: `Sources/SonosDrop/SonosDropApp.swift` (placeholder main so the executable target builds)
- Test: `Tests/SonosDropCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces: `Track`, `TrackStatus`, `SpeakerGroup` (with `queueURI`), `NowPlaying`, `TransportState`, `AudioFormat.mime(forExtension:)`, `AudioFormat.codecName(formatID:ext:)`, `TimeFormat.hms(_:)`, `TimeFormat.seconds(_:)`.

- [ ] **Step 1: Create Package.swift, .gitignore, Makefile**

```swift
// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SonosDrop",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SonosDropCore", swiftSettings: swift5),
        .executableTarget(name: "SonosDrop", dependencies: ["SonosDropCore"], swiftSettings: swift5),
        .testTarget(
            name: "SonosDropCoreTests",
            dependencies: ["SonosDropCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5),
    ]
)
```

`.gitignore`:
```
.build/
build/
.remember/
.DS_Store
*.swp
```

`Makefile` (tabs, not spaces, before recipe lines):
```make
.PHONY: test build app fixtures run clean

test:
	swift test

build:
	swift build

run: build
	.build/debug/SonosDrop

fixtures:
	scripts/make-fixtures.sh

app:
	scripts/bundle.sh

clean:
	rm -rf .build build
```

Then `git rm -r --cached .remember` so plugin memory stops being tracked.

- [ ] **Step 2: Create scripts/make-fixtures.sh and run it**

```bash
#!/bin/sh
# Generates 1-second stereo 440 Hz tones as Sonos-relevant fixtures.
set -e
OUT="$(dirname "$0")/../Tests/SonosDropCoreTests/Fixtures"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
python3 - "$TMP" <<'EOF'
import sys, math, wave
out = sys.argv[1]
def make(name, rate, bits):
    w = wave.open(f"{out}/{name}", 'wb'); w.setnchannels(2); w.setsampwidth(bits//8); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate):
        v = int(math.sin(2*math.pi*440*i/rate) * (2**(bits-1)-1) * 0.3)
        b = v.to_bytes(bits//8, 'little', signed=True); frames += b + b
    w.writeframes(bytes(frames)); w.close()
make('tone_16_44100.wav', 44100, 16)
make('tone_24_96000.wav', 96000, 24)
EOF
afconvert -f flac -d flac "$TMP/tone_16_44100.wav" "$OUT/tone_16_44100.flac"
afconvert -f flac -d flac "$TMP/tone_24_96000.wav" "$OUT/tone_24_96000.flac"
afconvert -f m4af -d aac  "$TMP/tone_16_44100.wav" "$OUT/tone_aac.m4a"
rm -rf "$TMP"
ls -la "$OUT"
```

Run: `chmod +x scripts/make-fixtures.sh && scripts/make-fixtures.sh`
Expected: three files listed, FLAC ~17 KB and ~44 KB, m4a ~8 KB.

- [ ] **Step 3: Write the failing models test**

`Tests/SonosDropCoreTests/ModelsTests.swift`:
```swift
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
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build error, `Track` not found.

- [ ] **Step 5: Write Models.swift and the placeholder app main**

`Sources/SonosDropCore/Models.swift`:
```swift
import Foundation
import AudioToolbox

public enum TrackStatus: Equatable, Sendable {
    case ready
    case queued
    case playing
    case unsupported(String)
    case failed(String)
}

public struct Track: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int
    public var codec: String
    public var status: TrackStatus

    public init(id: UUID = UUID(), url: URL, title: String? = nil, artist: String = "", album: String = "",
                duration: TimeInterval = 0, sampleRate: Double = 0, bitDepth: Int = 0, channels: Int = 2,
                codec: String = "", status: TrackStatus = .ready) {
        self.id = id
        self.url = url
        self.title = (title?.isEmpty == false) ? title! : url.deletingPathExtension().lastPathComponent
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.codec = codec.isEmpty ? AudioFormat.codecName(formatID: 0, ext: url.pathExtension) : codec
        self.status = status
    }

    public var mime: String { AudioFormat.mime(forExtension: url.pathExtension) }
    public var durationString: String { TimeFormat.hms(duration) }

    public var formatBadge: String {
        let khz: String
        if sampleRate <= 0 { khz = "" }
        else if sampleRate.truncatingRemainder(dividingBy: 1000) == 0 { khz = String(format: "%.0f", sampleRate / 1000) }
        else { khz = String(format: "%.1f", sampleRate / 1000) }
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF"].contains(codec)
        if lossless, bitDepth > 0, !khz.isEmpty { return "\(codec) \(bitDepth)/\(khz)" }
        return khz.isEmpty ? codec : "\(codec) \(khz)"
    }
}

public struct SpeakerGroup: Identifiable, Hashable, Sendable {
    public var id: String { coordinatorUUID }
    public let coordinatorUUID: String
    public let coordinatorIP: String
    public let name: String
    public let memberIPs: [String]

    public init(coordinatorUUID: String, coordinatorIP: String, name: String, memberIPs: [String]) {
        self.coordinatorUUID = coordinatorUUID
        self.coordinatorIP = coordinatorIP
        self.name = name
        self.memberIPs = memberIPs
    }

    public var queueURI: String { "x-rincon-queue:\(coordinatorUUID)#0" }
}

public enum TransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case unknown = ""
}

public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var state: TransportState
    public var trackNumber: Int

    public init(title: String = "", artist: String = "", elapsed: TimeInterval = 0, duration: TimeInterval = 0,
                state: TransportState = .unknown, trackNumber: Int = 0) {
        self.title = title; self.artist = artist; self.elapsed = elapsed
        self.duration = duration; self.state = state; self.trackNumber = trackNumber
    }

    public static let idle = NowPlaying()
}

public enum AudioFormat {
    public static let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "flac", "wav", "aif", "aiff", "ogg"]

    public static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    /// Codec label from the AudioToolbox format id, falling back to the extension.
    public static func codecName(formatID: UInt32, ext: String) -> String {
        switch formatID {
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "AAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatLinearPCM: return ["aif", "aiff"].contains(ext.lowercased()) ? "AIFF" : "WAV"
        default:
            switch ext.lowercased() {
            case "flac": return "FLAC"
            case "mp3": return "MP3"
            case "m4a", "mp4", "aac": return "AAC"
            case "wav": return "WAV"
            case "aif", "aiff": return "AIFF"
            case "ogg": return "OGG"
            default: return ext.uppercased()
            }
        }
    }
}

public enum TimeFormat {
    /// Sonos style H:MM:SS.
    public static func hms(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Parses H:MM:SS or H:MM:SS.fff; anything else is 0.
    public static func seconds(_ hms: String) -> TimeInterval {
        let parts = hms.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
```

`Sources/SonosDrop/SonosDropApp.swift` (temporary, replaced in Task 11):
```swift
import Foundation
import SonosDropCore

@main
struct SonosDropApp {
    static func main() {
        print("SonosDrop core loaded; UI arrives in Task 11")
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 6 tests ... passed`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: scaffold SonosDrop package with models and test fixtures

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 2: DIDL-Lite metadata builder

**Files:**
- Create: `Sources/SonosDropCore/DIDL.swift`
- Test: `Tests/SonosDropCoreTests/DIDLTests.swift`

**Interfaces:**
- Consumes: `Track` (Task 1).
- Produces: `XML.escape(_ s: String) -> String`, `DIDL.metadata(track: Track, streamURL: URL) -> String`, `DIDL.titleArtist(from didl: String) -> (title: String, artist: String)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SonosDropCore

@Test func escapesAllFiveXMLCharacters() {
    #expect(XML.escape("a & b < c > \"d\" 'e'") == "a &amp; b &lt; c &gt; &quot;d&quot; &apos;e&apos;")
}

@Test func buildsSonosCompatibleMetadata() {
    let track = Track(url: URL(fileURLWithPath: "/m/x.flac"), title: "Rock & Roll", artist: "AC/DC",
                      album: "Live <1992>", duration: 245, codec: "FLAC")
    let url = URL(string: "http://10.0.0.5:8080/t/abc")!
    let expected = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        + "<item id=\"t/abc\" parentID=\"-1\" restricted=\"true\">"
        + "<dc:title>Rock &amp; Roll</dc:title><dc:creator>AC/DC</dc:creator><upnp:album>Live &lt;1992&gt;</upnp:album>"
        + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        + "<res protocolInfo=\"http-get:*:audio/flac:*\" duration=\"0:04:05\">http://10.0.0.5:8080/t/abc</res>"
        + "</item></DIDL-Lite>"
    #expect(DIDL.metadata(track: track, streamURL: url) == expected)
}

@Test func readsTitleAndArtistBackFromSonosMetadata() {
    let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"-1\" parentID=\"-1\" restricted=\"true\"><dc:title>Self Care</dc:title><dc:creator>Mac Miller</dc:creator><upnp:album>Swimming</upnp:album></item></DIDL-Lite>"
    let r = DIDL.titleArtist(from: didl)
    #expect(r.title == "Self Care")
    #expect(r.artist == "Mac Miller")
}

@Test func titleArtistOnGarbageIsEmpty() {
    let r = DIDL.titleArtist(from: "NOT_IMPLEMENTED")
    #expect(r.title == "" && r.artist == "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DIDLTests 2>&1 | tail -3`
Expected: compile error, `XML`/`DIDL` not found.

- [ ] **Step 3: Implement DIDL.swift**

```swift
import Foundation

public enum XML {
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Collects the text of every leaf element, keyed by local name (prefix stripped).
final class XMLLeaves: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var current = ""
    private var text = ""

    static func collect(_ data: Data) -> [String: String] {
        let d = XMLLeaves()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.values
    }

    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = local(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        if name == current { values[name] = text }
        current = ""
        text = ""
    }
}

public enum DIDL {
    static let header = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"

    public static func metadata(track: Track, streamURL: URL) -> String {
        let itemID = "t/" + streamURL.lastPathComponent
        return header
            + "<item id=\"\(XML.escape(itemID))\" parentID=\"-1\" restricted=\"true\">"
            + "<dc:title>\(XML.escape(track.title))</dc:title>"
            + "<dc:creator>\(XML.escape(track.artist))</dc:creator>"
            + "<upnp:album>\(XML.escape(track.album))</upnp:album>"
            + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(track.mime):*\" duration=\"\(track.durationString)\">\(XML.escape(streamURL.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }

    public static func titleArtist(from didl: String) -> (title: String, artist: String) {
        guard didl.hasPrefix("<") else { return ("", "") }
        let v = XMLLeaves.collect(Data(didl.utf8))
        return (v["title"] ?? "", v["creator"] ?? "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DIDLTests 2>&1 | tail -3`
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/DIDL.swift Tests/SonosDropCoreTests/DIDLTests.swift
git commit -m "feat: DIDL-Lite metadata builder and parser

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 3: HTTP request parsing and Range header

**Files:**
- Create: `Sources/SonosDropCore/HTTPRequest.swift`
- Test: `Tests/SonosDropCoreTests/HTTPRequestTests.swift`

**Interfaces:**
- Produces: `HTTPRequest { method, path, headers }` with `static func parse(_ data: Data) -> HTTPRequest?` (nil while incomplete), `RangeResult { .full, .partial(Range<Int>), .unsatisfiable }`, `RangeParser.parse(_ header: String?, fileSize: Int) -> RangeResult`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HTTPRequestTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement HTTPRequest.swift**

```swift
import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]

    /// Returns nil until the full header block ("\r\n\r\n") has arrived.
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers)
    }
}

public enum RangeResult: Equatable, Sendable {
    case full
    case partial(Range<Int>)
    case unsatisfiable
}

public enum RangeParser {
    /// Single-range subset of RFC 7233. Multi-range requests use the first range only.
    public static func parse(_ header: String?, fileSize: Int) -> RangeResult {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        if startStr.isEmpty {
            guard let suffix = Int(endStr), suffix > 0 else { return .full }
            return .partial(max(0, fileSize - suffix)..<fileSize)
        }
        guard let start = Int(startStr) else { return .full }
        guard start < fileSize else { return .unsatisfiable }
        let end = endStr.isEmpty ? fileSize - 1 : min(Int(endStr) ?? (fileSize - 1), fileSize - 1)
        guard end >= start else { return .unsatisfiable }
        return .partial(start..<(end + 1))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HTTPRequestTests 2>&1 | tail -3`
Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/HTTPRequest.swift Tests/SonosDropCoreTests/HTTPRequestTests.swift
git commit -m "feat: HTTP request and Range header parsing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 4: Local IP helper and MediaServer

**Files:**
- Create: `Sources/SonosDropCore/LocalIP.swift`, `Sources/SonosDropCore/MediaServer.swift`
- Test: `Tests/SonosDropCoreTests/MediaServerTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest.parse`, `RangeParser.parse`, `AudioFormat.mime(forExtension:)`.
- Produces:
  ```swift
  public enum LocalIP { public static func primaryIPv4() -> String? }
  public protocol MediaServing: AnyObject {
      var port: UInt16 { get }
      var host: String { get }                  // LAN IPv4 used in URLs
      var onAddressChange: (() -> Void)? { get set }
      func start() async throws
      func stop()
      func register(_ fileURL: URL) -> String   // returns token
      func url(forToken token: String) -> URL?
      func unregisterAll()
  }
  public final class MediaServer: MediaServing
  ```
  Test-only: `MediaServer(hostOverride: "127.0.0.1")`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MediaServerTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement LocalIP.swift**

```swift
import Foundation
import Darwin

public enum LocalIP {
    /// First IPv4 on an "en*" interface (Wi-Fi/Ethernet), else any non-loopback IPv4.
    public static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }
}
```

- [ ] **Step 4: Implement MediaServer.swift**

```swift
import Foundation
import Network

public protocol MediaServing: AnyObject {
    var port: UInt16 { get }
    var host: String { get }
    var onAddressChange: (() -> Void)? { get set }
    func start() async throws
    func stop()
    func register(_ fileURL: URL) -> String
    func url(forToken token: String) -> URL?
    func unregisterAll()
}

public enum MediaServerError: Error { case listenerFailed(String), noAddress }

public final class MediaServer: MediaServing, @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var onAddressChange: (() -> Void)?
    public var host: String { hostOverride ?? currentHost }

    private let hostOverride: String?
    private var currentHost = ""
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "sonosdrop.mediaserver")
    private let lock = NSLock()
    private var files: [String: URL] = [:]
    private static let chunkSize = 256 * 1024

    public init(hostOverride: String? = nil) {
        self.hostOverride = hostOverride
    }

    // MARK: lifecycle

    public func start() async throws {
        currentHost = LocalIP.primaryIPv4() ?? ""
        if hostOverride == nil && currentHost.isEmpty { throw MediaServerError.noAddress }
        try await startListener()
        if hostOverride == nil { startMonitor() }
    }

    public func stop() {
        monitor?.cancel(); monitor = nil
        listener?.cancel(); listener = nil
        port = 0
    }

    private func startListener() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        listener?.cancel()
        listener = l
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: MediaServerError.listenerFailed(String(describing: err))) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
    }

    /// Rebinds when the Mac's LAN address changes (sleep/wake, Wi-Fi switch) and tells the model.
    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            let ip = LocalIP.primaryIPv4() ?? ""
            guard !ip.isEmpty, ip != self.currentHost else { return }
            self.currentHost = ip
            Task { [weak self] in
                guard let self else { return }
                try? await self.startListener()
                self.onAddressChange?()
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    // MARK: registry

    public func register(_ fileURL: URL) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock(); files[token] = fileURL; lock.unlock()
        return token
    }

    public func url(forToken token: String) -> URL? {
        lock.lock(); let known = files[token] != nil; lock.unlock()
        guard known, port != 0, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)/t/\(token)")
    }

    public func unregisterAll() {
        lock.lock(); files.removeAll(); lock.unlock()
    }

    private func file(forToken token: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return files[token]
    }

    // MARK: connections

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) { self.respond(to: req, on: conn); return }
            if isComplete || error != nil || buf.count > 65536 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(to req: HTTPRequest, on conn: NWConnection) {
        guard req.method == "GET" || req.method == "HEAD", req.path.hasPrefix("/t/"),
              let file = file(forToken: String(req.path.dropFirst(3))),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        else { send(status: "404 Not Found", headers: ["Content-Length": "0"], body: nil, on: conn); return }

        var headers = ["Content-Type": AudioFormat.mime(forExtension: file.pathExtension), "Accept-Ranges": "bytes"]
        let range: Range<Int>
        let status: String
        switch RangeParser.parse(req.headers["range"], fileSize: size) {
        case .unsatisfiable:
            send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"], body: nil, on: conn)
            return
        case .full:
            range = 0..<size; status = "200 OK"
        case .partial(let r):
            range = r; status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(size)"
        }
        headers["Content-Length"] = "\(range.count)"
        let body: (URL, Range<Int>)? = req.method == "HEAD" ? nil : (file, range)
        send(status: status, headers: headers, body: body, on: conn)
    }

    private func send(status: String, headers: [String: String], body: (URL, Range<Int>)?, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\nServer: SonosDrop\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self, let body else {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            guard let fh = try? FileHandle(forReadingFrom: body.0) else { conn.cancel(); return }
            try? fh.seek(toOffset: UInt64(body.1.lowerBound))
            self.stream(fh, remaining: body.1.count, on: conn)
        })
    }

    private func stream(_ fh: FileHandle, remaining: Int, on conn: NWConnection) {
        guard remaining > 0 else {
            try? fh.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let chunk = (try? fh.read(upToCount: min(Self.chunkSize, remaining))) ?? Data()
        guard !chunk.isEmpty else { try? fh.close(); conn.cancel(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? fh.close(); conn.cancel(); return }
            self.stream(fh, remaining: remaining - chunk.count, on: conn)
        })
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MediaServerTests 2>&1 | tail -5`
Expected: 6 tests passed. If macOS shows a firewall prompt for the test runner, click Allow; the server binds all interfaces.

- [ ] **Step 6: Commit**

```bash
git add Sources/SonosDropCore/LocalIP.swift Sources/SonosDropCore/MediaServer.swift Tests/SonosDropCoreTests/MediaServerTests.swift
git commit -m "feat: HTTP media server with range support and LAN address detection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 5: TrackInspector

**Files:**
- Create: `Sources/SonosDropCore/TrackInspector.swift`
- Test: `Tests/SonosDropCoreTests/TrackInspectorTests.swift`

**Interfaces:**
- Consumes: `Track`, `TrackStatus`, `AudioFormat`.
- Produces: `TrackInspector.inspect(_ url: URL) -> Track`, `TrackInspector.expand(_ urls: [URL]) -> [URL]`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TrackInspectorTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement TrackInspector.swift**

```swift
import Foundation
import AudioToolbox

public enum TrackInspector {
    /// Folders are walked one level deep (supported extensions only, sorted, hidden skipped).
    /// Files dropped directly are always included so the user sees why one is rejected.
    public static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                let files = items.filter {
                    ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
                        && AudioFormat.supportedExtensions.contains($0.pathExtension.lowercased())
                }
                out += files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                out.append(url)
            }
        }
        return out
    }

    public static func inspect(_ url: URL) -> Track {
        let ext = url.pathExtension.lowercased()
        guard AudioFormat.supportedExtensions.contains(ext) else {
            return Track(url: url, status: .unsupported("Format .\(ext) not supported by Sonos"))
        }
        // AudioToolbox cannot open Ogg Vorbis; Sonos can play it. Pass it through unprobed.
        if ext == "ogg" {
            return FileManager.default.fileExists(atPath: url.path)
                ? Track(url: url, codec: "OGG")
                : Track(url: url, codec: "OGG", status: .unsupported("Can't read file"))
        }

        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let file = fileID else {
            return Track(url: url, status: .unsupported("Can't read file"))
        }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)

        var sourceBits: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &sourceBits)
        let bitDepth = Int(asbd.mBitsPerChannel != 0 ? asbd.mBitsPerChannel : sourceBits)

        var duration: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        var dictRef: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var tags: [String: Any] = [:]
        if AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dictRef) == noErr, let d = dictRef?.takeRetainedValue() as? [String: Any] {
            tags = d
        }

        let codec = AudioFormat.codecName(formatID: asbd.mFormatID, ext: ext)
        var track = Track(url: url,
                          title: tags["title"] as? String,
                          artist: tags["artist"] as? String ?? "",
                          album: tags["album"] as? String ?? "",
                          duration: duration,
                          sampleRate: asbd.mSampleRate,
                          bitDepth: bitDepth,
                          channels: Int(asbd.mChannelsPerFrame),
                          codec: codec)
        if asbd.mSampleRate > 48000 {
            track.status = .unsupported("\(Int(asbd.mSampleRate / 1000)) kHz, Sonos max is 48")
        } else if bitDepth > 24 {
            track.status = .unsupported("\(bitDepth)-bit, Sonos max is 24")
        } else if asbd.mChannelsPerFrame > 2 {
            track.status = .unsupported("Multichannel audio")
        }
        return track
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TrackInspectorTests 2>&1 | tail -3`
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/TrackInspector.swift Tests/SonosDropCoreTests/TrackInspectorTests.swift
git commit -m "feat: track inspector with Sonos playability rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 6: SOAP envelope and response parsing

**Files:**
- Create: `Sources/SonosDropCore/SOAP.swift`
- Test: `Tests/SonosDropCoreTests/SOAPTests.swift`

**Interfaces:**
- Consumes: `XML.escape`, `XMLLeaves.collect` (Task 2).
- Produces:
  ```swift
  public enum SonosService: String { case avTransport, renderingControl, groupRenderingControl, zoneGroupTopology
      var controlPath: String; var urn: String }
  public enum SonosError: Error, Equatable { case unreachable(String), upnp(Int), http(Int), badResponse(String), noSpeakers }
  public enum SOAP {
      static func envelope(service: SonosService, action: String, args: [(String, String)]) -> String
      static func parseResponse(_ data: Data) throws -> [String: String]
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SonosDropCore

@Test func servicePathsAndURNs() {
    #expect(SonosService.avTransport.controlPath == "/MediaRenderer/AVTransport/Control")
    #expect(SonosService.zoneGroupTopology.controlPath == "/ZoneGroupTopology/Control")
    #expect(SonosService.groupRenderingControl.urn == "urn:schemas-upnp-org:service:GroupRenderingControl:1")
}

@Test func envelopeEscapesArguments() {
    let xml = SOAP.envelope(service: .avTransport, action: "AddURIToQueue", args: [("InstanceID", "0"), ("EnqueuedURIMetaData", "<a href=\"x\">")])
    #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:AddURIToQueue xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    #expect(xml.contains("<InstanceID>0</InstanceID><EnqueuedURIMetaData>&lt;a href=&quot;x&quot;&gt;</EnqueuedURIMetaData>"))
    #expect(xml.hasSuffix("</u:AddURIToQueue></s:Body></s:Envelope>"))
}

@Test func parsesResponseLeaves() throws {
    let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetPositionInfoResponse xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><Track>5</Track><TrackDuration>0:05:45</TrackDuration><TrackMetaData>&lt;DIDL-Lite&gt;&lt;dc:title&gt;Self Care&lt;/dc:title&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><RelTime>0:01:24</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>"
    let v = try SOAP.parseResponse(Data(body.utf8))
    #expect(v["Track"] == "5")
    #expect(v["RelTime"] == "0:01:24")
    #expect(v["TrackMetaData"] == "<DIDL-Lite><dc:title>Self Care</dc:title></DIDL-Lite>")
}

@Test func upnpFaultBecomesError() {
    let fault = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>714</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
    #expect(throws: SonosError.upnp(714)) { try SOAP.parseResponse(Data(fault.utf8)) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SOAPTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement SOAP.swift**

```swift
import Foundation

public enum SonosService: String, Sendable {
    case avTransport = "AVTransport"
    case renderingControl = "RenderingControl"
    case groupRenderingControl = "GroupRenderingControl"
    case zoneGroupTopology = "ZoneGroupTopology"

    public var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        }
    }

    public var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
}

public enum SonosError: Error, Equatable, Sendable {
    case unreachable(String)
    case upnp(Int)
    case http(Int)
    case badResponse(String)
    case noSpeakers

    public var message: String {
        switch self {
        case .unreachable(let ip): return "Speaker at \(ip) is unreachable"
        case .upnp(let code): return "Sonos rejected the request (UPnP \(code))"
        case .http(let status): return "Speaker answered HTTP \(status)"
        case .badResponse(let why): return "Unexpected reply: \(why)"
        case .noSpeakers: return "No Sonos speakers found"
        }
    }
}

public enum SOAP {
    public static func envelope(service: SonosService, action: String, args: [(String, String)]) -> String {
        let body = args.map { "<\($0.0)>\(XML.escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"
    }

    /// Flat map of leaf element name -> text. Throws `SonosError.upnp` on a UPnP fault.
    public static func parseResponse(_ data: Data) throws -> [String: String] {
        let values = XMLLeaves.collect(data)
        if let code = values["errorCode"], let n = Int(code) { throw SonosError.upnp(n) }
        if values.isEmpty { throw SonosError.badResponse("empty or malformed XML") }
        return values
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SOAPTests 2>&1 | tail -3`
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/SOAP.swift Tests/SonosDropCoreTests/SOAPTests.swift
git commit -m "feat: SOAP envelope builder and UPnP response parser

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 7: Topology parser and SSDP

**Files:**
- Create: `Sources/SonosDropCore/Topology.swift`
- Test: `Tests/SonosDropCoreTests/TopologyTests.swift`

**Interfaces:**
- Consumes: `SpeakerGroup`.
- Produces: `TopologyParser.parse(_ zoneGroupStateXML: String) -> [SpeakerGroup]`, `SSDP.searchMessage() -> String`, `SSDP.locationHost(inReply reply: String) -> String?`, `SSDP.discoverHosts(timeout: TimeInterval) async -> [String]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SonosDropCore

// Captured from the user's network (trimmed) plus a synthetic 2-room group and an invisible bridge.
let topologyXML = """
<ZoneGroupState><ZoneGroups>\
<ZoneGroup Coordinator="RINCON_347E5CDB811801400" ID="RINCON_347E5CDB811801400:123">\
<ZoneGroupMember UUID="RINCON_C43875F099E001400" Location="http://10.20.28.56:1400/xml/device_description.xml" ZoneName="Studio" Icon="x-rincon-roomicon:office" SWGen="2"/>\
<ZoneGroupMember UUID="RINCON_347E5CDB811801400" Location="http://10.20.28.52:1400/xml/device_description.xml" ZoneName="Studio" Icon="x-rincon-roomicon:office" SWGen="2"/>\
</ZoneGroup>\
<ZoneGroup Coordinator="RINCON_AAA" ID="RINCON_AAA:5">\
<ZoneGroupMember UUID="RINCON_AAA" Location="http://10.20.28.60:1400/xml/device_description.xml" ZoneName="Kitchen"/>\
<ZoneGroupMember UUID="RINCON_BBB" Location="http://10.20.28.61:1400/xml/device_description.xml" ZoneName="Patio"/>\
</ZoneGroup>\
<ZoneGroup Coordinator="RINCON_BOOST" ID="RINCON_BOOST:1">\
<ZoneGroupMember UUID="RINCON_BOOST" Location="http://10.20.28.70:1400/xml/device_description.xml" ZoneName="BOOST" Invisible="1"/>\
</ZoneGroup>\
</ZoneGroups><VanishedDevices/></ZoneGroupState>
"""

@Test func stereoPairCollapsesToCoordinator() {
    let groups = TopologyParser.parse(topologyXML)
    let studio = groups.first { $0.name == "Studio" }
    #expect(studio?.coordinatorIP == "10.20.28.52")
    #expect(studio?.coordinatorUUID == "RINCON_347E5CDB811801400")
    #expect(studio?.memberIPs.sorted() == ["10.20.28.52", "10.20.28.56"])
}

@Test func multiRoomGroupJoinsNamesAndInvisibleGroupsAreDropped() {
    let groups = TopologyParser.parse(topologyXML)
    #expect(groups.count == 2)
    #expect(groups.map(\.name).sorted() == ["Kitchen + Patio", "Studio"])
}

@Test func garbageYieldsNoGroups() {
    #expect(TopologyParser.parse("nope").isEmpty)
}

@Test func ssdpSearchMessageTargetsZonePlayers() {
    let m = SSDP.searchMessage()
    #expect(m.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
    #expect(m.contains("HOST: 239.255.255.250:1900\r\n"))
    #expect(m.contains("MAN: \"ssdp:discover\"\r\n"))
    #expect(m.contains("ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n"))
    #expect(m.hasSuffix("\r\n\r\n"))
}

@Test func ssdpReplyLocationHost() {
    let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nEXT:\r\nLOCATION: http://10.20.28.52:1400/xml/device_description.xml\r\nSERVER: Linux UPnP/1.0 Sonos/97.1-80312 (ZPS24)\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
    #expect(SSDP.locationHost(inReply: reply) == "10.20.28.52")
    #expect(SSDP.locationHost(inReply: "HTTP/1.1 200 OK\r\n\r\n") == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TopologyTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement Topology.swift**

```swift
import Foundation
import Darwin

public enum TopologyParser {
    public static func parse(_ xml: String) -> [SpeakerGroup] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.groups
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var groups: [SpeakerGroup] = []
        private var coordinator = ""
        private var members: [(uuid: String, ip: String, name: String, invisible: Bool)] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            switch elementName {
            case "ZoneGroup":
                coordinator = a["Coordinator"] ?? ""
                members = []
            case "ZoneGroupMember", "Satellite":
                guard let uuid = a["UUID"], let loc = a["Location"], let host = URL(string: loc)?.host else { return }
                members.append((uuid, host, a["ZoneName"] ?? "", a["Invisible"] == "1"))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard elementName == "ZoneGroup", let coord = members.first(where: { $0.uuid == coordinator }) else { return }
            let visible = members.filter { !$0.invisible }
            guard !visible.isEmpty else { return }
            var names: [String] = []
            for m in visible where !names.contains(m.name) { names.append(m.name) }
            groups.append(SpeakerGroup(coordinatorUUID: coordinator, coordinatorIP: coord.ip,
                                       name: names.joined(separator: " + "), memberIPs: members.map(\.ip)))
        }
    }
}

public enum SSDP {
    public static func searchMessage() -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
    }

    public static func locationHost(inReply reply: String) -> String? {
        for line in reply.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            return URL(string: value)?.host
        }
        return nil
    }

    /// Multicast M-SEARCH twice, collect unique reply hosts until the timeout. Blocking work runs off the caller's thread.
    public static func discoverHosts(timeout: TimeInterval = 3) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: blockingSearch(timeout: timeout)) }
        }
    }

    static func blockingSearch(timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = Array(searchMessage().utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, msg, msg.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var hosts = Set<String>()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if let s = String(bytes: buf[0..<Int(n)], encoding: .utf8), let host = locationHost(inReply: s) { hosts.insert(host) }
        }
        return hosts.sorted()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TopologyTests 2>&1 | tail -3`
Expected: 5 tests passed.

- [ ] **Step 5: Smoke-test SSDP against the real network**

Add this test to `TopologyTests.swift`:

```swift
@Test(.disabled("manual: needs LAN")) func ssdpFindsRealSpeakers() async {
    let hosts = await SSDP.discoverHosts(timeout: 3)
    print("SSDP hosts:", hosts)
    #expect(hosts.contains("10.20.28.52"))
}
```
Run once with the `.disabled` trait removed: `swift test --filter ssdpFindsRealSpeakers 2>&1 | grep -E 'SSDP hosts|passed|failed'`.
Expected: `SSDP hosts: ["10.20.28.52", "10.20.28.56"]` (order may vary). Put the trait back before committing so CI-style runs stay LAN-independent.

- [ ] **Step 6: Commit**

```bash
git add Sources/SonosDropCore/Topology.swift Tests/SonosDropCoreTests/TopologyTests.swift
git commit -m "feat: zone topology parser and SSDP discovery

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 8: SonosClient

**Files:**
- Create: `Sources/SonosDropCore/SonosClient.swift`
- Test: `Tests/SonosDropCoreTests/SonosClientTests.swift`

**Interfaces:**
- Consumes: `SOAP`, `SonosService`, `SonosError`, `SpeakerGroup`, `NowPlaying`, `TransportState`, `DIDL.titleArtist`, `TimeFormat.seconds`.
- Produces:
  ```swift
  public protocol SonosControlling: Sendable {
      func clearQueue(_ g: SpeakerGroup) async throws
      func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int   // FirstTrackNumberEnqueued
      func playQueue(_ g: SpeakerGroup) async throws            // SetAVTransportURI + Seek TRACK_NR 1 + Play
      func play(_ g: SpeakerGroup) async throws
      func pause(_ g: SpeakerGroup) async throws
      func next(_ g: SpeakerGroup) async throws
      func previous(_ g: SpeakerGroup) async throws
      func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying
      func volume(_ g: SpeakerGroup) async throws -> Int
      func setVolume(_ g: SpeakerGroup, _ value: Int) async throws
      func zoneGroupStateXML(ip: String) async throws -> String
  }
  public final class SonosClient: SonosControlling {
      public init(session: URLSession = .shared)
      public func invoke(ip: String, service: SonosService, action: String, args: [(String, String)]) async throws -> [String: String]
  }
  ```

- [ ] **Step 1: Write the failing test (URLProtocol stub)**

```swift
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

private let studio = SpeakerGroup(coordinatorUUID: "RINCON_347E5CDB811801400", coordinatorIP: "10.20.28.52", name: "Studio", memberIPs: ["10.20.28.52", "10.20.28.56"])

private func response(_ action: String, _ inner: String) -> String {
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>"
}

@Test func addToQueueTargetsCoordinatorWithSoapHeaders() async throws {
    StubProtocol.status = 200
    StubProtocol.responseBody = response("AddURIToQueue", "<FirstTrackNumberEnqueued>3</FirstTrackNumberEnqueued><NumTracksAdded>1</NumTracksAdded><NewQueueLength>3</NewQueueLength>")
    let n = try await stubClient().addToQueue(studio, uri: "http://10.20.28.66:5000/t/abc", metadata: "<DIDL-Lite/>")
    #expect(n == 3)
    let req = StubProtocol.lastRequest!
    #expect(req.url?.absoluteString == "http://10.20.28.52:1400/MediaRenderer/AVTransport/Control")
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

@Test func unreachableHostIsMapped() async {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 1
    let client = SonosClient(session: URLSession(configuration: cfg))
    let dead = SpeakerGroup(coordinatorUUID: "X", coordinatorIP: "10.255.255.1", name: "Dead", memberIPs: [])
    await #expect(throws: SonosError.unreachable("10.255.255.1")) { try await client.pause(dead) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SonosClientTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement SonosClient.swift**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SonosClientTests 2>&1 | tail -3`
Expected: 4 tests passed. The unreachable test takes about one second.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/SonosClient.swift Tests/SonosDropCoreTests/SonosClientTests.swift
git commit -m "feat: Sonos UPnP client for queue, transport, volume and topology

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 9: Discovery

**Files:**
- Create: `Sources/SonosDropCore/Discovery.swift`
- Test: add to `Tests/SonosDropCoreTests/TopologyTests.swift`

**Interfaces:**
- Consumes: `SSDP.discoverHosts`, `SonosControlling.zoneGroupStateXML`, `TopologyParser.parse`.
- Produces:
  ```swift
  public protocol GroupDiscovering: Sendable { func groups(manualIP: String?) async throws -> [SpeakerGroup] }
  public final class Discovery: GroupDiscovering {
      public init(client: SonosControlling, ssdp: @escaping @Sendable (TimeInterval) async -> [String] = SSDP.discoverHosts)
  }
  ```

- [ ] **Step 1: Write the failing test**

Append to `TopologyTests.swift`:
```swift
final class TopologyOnlyClient: SonosControlling, @unchecked Sendable {
    var askedIPs: [String] = []
    let xml: String
    init(xml: String) { self.xml = xml }
    func zoneGroupStateXML(ip: String) async throws -> String { askedIPs.append(ip); return xml }
    func clearQueue(_ g: SpeakerGroup) async throws {}
    func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int { 0 }
    func playQueue(_ g: SpeakerGroup) async throws {}
    func play(_ g: SpeakerGroup) async throws {}
    func pause(_ g: SpeakerGroup) async throws {}
    func next(_ g: SpeakerGroup) async throws {}
    func previous(_ g: SpeakerGroup) async throws {}
    func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying { .idle }
    func volume(_ g: SpeakerGroup) async throws -> Int { 0 }
    func setVolume(_ g: SpeakerGroup, _ value: Int) async throws {}
}

@Test func discoveryUsesFirstSSDPHostAndParsesGroups() async throws {
    let client = TopologyOnlyClient(xml: topologyXML)
    let discovery = Discovery(client: client, ssdp: { _ in ["10.20.28.52", "10.20.28.56"] })
    let groups = try await discovery.groups(manualIP: nil)
    #expect(client.askedIPs == ["10.20.28.52"])
    #expect(groups.map(\.name).sorted() == ["Kitchen + Patio", "Studio"])
}

@Test func discoveryFallsBackToManualIP() async throws {
    let client = TopologyOnlyClient(xml: topologyXML)
    let discovery = Discovery(client: client, ssdp: { _ in [] })
    _ = try await discovery.groups(manualIP: "10.20.28.52")
    #expect(client.askedIPs == ["10.20.28.52"])
}

@Test func discoveryWithNothingThrowsNoSpeakers() async {
    let discovery = Discovery(client: TopologyOnlyClient(xml: topologyXML), ssdp: { _ in [] })
    await #expect(throws: SonosError.noSpeakers) { try await discovery.groups(manualIP: nil) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TopologyTests 2>&1 | tail -3`
Expected: compile error, `Discovery` not found.

- [ ] **Step 3: Implement Discovery.swift**

```swift
import Foundation

public protocol GroupDiscovering: Sendable {
    func groups(manualIP: String?) async throws -> [SpeakerGroup]
}

public final class Discovery: GroupDiscovering, @unchecked Sendable {
    private let client: SonosControlling
    private let ssdp: @Sendable (TimeInterval) async -> [String]

    public init(client: SonosControlling, ssdp: @escaping @Sendable (TimeInterval) async -> [String] = { await SSDP.discoverHosts(timeout: $0) }) {
        self.client = client
        self.ssdp = ssdp
    }

    /// Manual IP wins when given; otherwise the first SSDP responder is asked for the whole household.
    public func groups(manualIP: String?) async throws -> [SpeakerGroup] {
        var hosts: [String] = []
        if let manualIP, !manualIP.trimmingCharacters(in: .whitespaces).isEmpty {
            hosts = [manualIP.trimmingCharacters(in: .whitespaces)]
        } else {
            hosts = await ssdp(3)
        }
        guard let first = hosts.first else { throw SonosError.noSpeakers }
        let xml = try await client.zoneGroupStateXML(ip: first)
        let groups = TopologyParser.parse(xml)
        guard !groups.isEmpty else { throw SonosError.badResponse("topology had no visible groups") }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TopologyTests 2>&1 | tail -3`
Expected: 8 tests passed (5 from Task 7 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDropCore/Discovery.swift Tests/SonosDropCoreTests/TopologyTests.swift
git commit -m "feat: speaker group discovery with manual IP fallback

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 10: QueueModel

**Files:**
- Create: `Sources/SonosDropCore/QueueModel.swift`
- Test: `Tests/SonosDropCoreTests/QueueModelTests.swift`

**Interfaces:**
- Consumes: `SonosControlling`, `GroupDiscovering`, `MediaServing`, `TrackInspector.inspect/expand`, `DIDL.metadata`, `SonosError.message`.
- Produces:
  ```swift
  @MainActor @Observable public final class QueueModel {
      public var groups: [SpeakerGroup], selectedGroup: SpeakerGroup?, tracks: [Track]
      public var nowPlaying: NowPlaying, volume: Int, serverStatus: String, lastError: String?
      public var needsResend: Bool, coordinatorReachable: Bool, isBusy: Bool, manualIP: String
      public init(client: SonosControlling, discovery: GroupDiscovering, server: MediaServing,
                  inspector: @escaping @Sendable (URL) -> Track = TrackInspector.inspect)
      public func start() async
      public func refreshGroups() async
      public func drop(_ urls: [URL]) async
      public func play() async; pause(); next(); previous(); setVolume(_ v: Int) async
      public func startPolling(); stopPolling()
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
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

final class FakeServer: MediaServing, @unchecked Sendable {
    var port: UInt16 = 5000
    var host = "10.0.0.9"
    var onAddressChange: (() -> Void)?
    var tokens: [String: URL] = [:]
    var started = false
    private var counter = 0
    func start() async throws { started = true }
    func stop() { started = false }
    func register(_ fileURL: URL) -> String { counter += 1; let t = "tok\(counter)"; tokens[t] = fileURL; return t }
    func url(forToken token: String) -> URL? { tokens[token] == nil ? nil : URL(string: "http://\(host):\(port)/t/\(token)") }
    func unregisterAll() { tokens.removeAll() }
}

struct FakeDiscovery: GroupDiscovering {
    let result: Result<[SpeakerGroup], SonosError>
    func groups(manualIP: String?) async throws -> [SpeakerGroup] { try result.get() }
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter QueueModelTests 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 3: Implement QueueModel.swift**

```swift
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
                inspector: @escaping @Sendable (URL) -> Track = TrackInspector.inspect) {
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

        let files = TrackInspector.expand(urls)
        let inspect = inspector
        tracks = await Task.detached { files.map(inspect) }.value
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
                await self?.pollOnce()
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QueueModelTests 2>&1 | tail -3`
Expected: 9 tests passed.

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (about 45).

- [ ] **Step 6: Commit**

```bash
git add Sources/SonosDropCore/QueueModel.swift Tests/SonosDropCoreTests/QueueModelTests.swift
git commit -m "feat: observable queue model orchestrating drop, transport and polling

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 11: Menu bar app, view, and bundle script

> **Execution ruling (2026-09-19):** the SwiftUI property-wrapper macros (`@State`, `@Bindable`,
> `@Environment`) ship only with Xcode, not the Command Line Tools. The code below is kept for the
> record, but the implementation must avoid every SwiftUI property wrapper: the App holds
> `let model: QueueModel` and `let ui = MenuBarUIState()` (an `@Observable` class for view-local
> state), views take them as plain `let` properties, and every binding is `Binding(get:set:)`.

**Files:**
- Replace: `Sources/SonosDrop/SonosDropApp.swift`
- Create: `Sources/SonosDrop/MenuBarView.swift`, `scripts/bundle.sh`
- Modify: `Makefile` (the `app` target already calls `scripts/bundle.sh`)

**Interfaces:**
- Consumes: `QueueModel` and everything it exposes, `SonosClient`, `Discovery`, `MediaServer`.
- Produces: `build/SonosDrop.app`, installed to `/Applications/SonosDrop.app`.

No unit tests: SwiftUI views are verified by the manual checklist in Task 12. The build itself is the check.

- [ ] **Step 1: Write SonosDropApp.swift**

```swift
import SwiftUI
import SonosDropCore

@main
struct SonosDropApp: App {
    @State private var model: QueueModel = {
        let client = SonosClient()
        return QueueModel(client: client, discovery: Discovery(client: client), server: MediaServer())
    }()

    var body: some Scene {
        MenuBarExtra("SonosDrop", systemImage: "hifispeaker.2.fill") {
            MenuBarView(model: model)
                .frame(width: 320, height: 480)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 2: Write MenuBarView.swift**

```swift
import SwiftUI
import SonosDropCore

struct MenuBarView: View {
    @Bindable var model: QueueModel
    @State private var showManualIP = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.tracks.isEmpty { dropZone } else { trackList }
            Divider()
            footer
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.drop(urls) }
            return true
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Speaker", selection: $model.selectedGroup) {
                    if model.groups.isEmpty { Text("No speakers").tag(SpeakerGroup?.none) }
                    ForEach(model.groups) { g in Text(g.name).tag(Optional(g)) }
                }
                .labelsHidden()
                Button { Task { await model.refreshGroups() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                    .help("Search for speakers again")
                Button { showManualIP.toggle() } label: { Image(systemName: "network") }
                    .buttonStyle(.borderless)
                    .help("Enter a speaker IP manually")
            }
            if showManualIP {
                TextField("Speaker IP, e.g. 10.20.28.52", text: $model.manualIP)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refreshGroups() }; showManualIP = false }
            }
        }
        .padding(10)
    }

    // MARK: body

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Drop songs or a folder here").font(.headline)
            Text("FLAC, MP3, AAC, ALAC, WAV, AIFF, OGG up to 24-bit/48 kHz")
                .font(.caption).foregroundStyle(.secondary)
            Text("macOS may ask to allow incoming connections. The speaker pulls the files from this Mac, so click Allow.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var trackList: some View {
        List(model.tracks) { track in
            HStack(alignment: .firstTextBaseline) {
                statusIcon(track.status).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1)
                    Text(track.artist.isEmpty ? track.formatBadge : "\(track.artist) · \(track.formatBadge)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let reason = reason(track.status) {
                        Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer()
                Text(track.durationString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    private func statusIcon(_ s: TrackStatus) -> some View {
        Group {
            switch s {
            case .playing: Image(systemName: "speaker.wave.2.fill").foregroundStyle(.green)
            case .queued: Image(systemName: "list.bullet").foregroundStyle(.secondary)
            case .ready: Image(systemName: "circle").foregroundStyle(.secondary)
            case .unsupported, .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private func reason(_ s: TrackStatus) -> String? {
        switch s {
        case .unsupported(let r), .failed(let r): return r
        default: return nil
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.white)
                    .padding(6).frame(maxWidth: .infinity)
                    .background(model.needsResend ? Color.orange : Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.nowPlaying.title.isEmpty ? "Nothing playing" : model.nowPlaying.title).lineLimit(1)
                    Text(model.nowPlaying.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(TimeFormat.hms(model.nowPlaying.elapsed)) / \(TimeFormat.hms(model.nowPlaying.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button { Task { await model.previous() } } label: { Image(systemName: "backward.fill") }
                Button {
                    Task {
                        if model.nowPlaying.state == .playing { await model.pause() } else { await model.play() }
                    }
                } label: {
                    Image(systemName: model.nowPlaying.state == .playing ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { Task { await model.next() } } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedGroup == nil || !model.coordinatorReachable)
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.volume) },
                                      set: { v in Task { await model.setVolume(Int(v)) } }), in: 0...100)
                Text("\(model.volume)").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
            }
            .disabled(model.selectedGroup == nil || !model.coordinatorReachable)
            HStack {
                Text(model.serverStatus).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.caption)
            }
        }
        .padding(10)
    }
}
```

- [ ] **Step 3: Build and launch from the terminal**

Run: `swift build 2>&1 | tail -3 && .build/debug/SonosDrop &`
Expected: a speaker icon appears in the menu bar. Click it: the popover shows "Studio" selected and "Serving from 10.20.28.66:<port>". Stop with `kill %1` when done. If the first launch triggers "accept incoming network connections", click Allow.

Common compile fixes:
- `Picker` selection needs `Optional(g)` tags matching `SpeakerGroup?` (already done).
- If `@Bindable` complains, confirm `QueueModel` is `@Observable` and the target imports `SwiftUI`.

- [ ] **Step 4: Write scripts/bundle.sh**

```bash
#!/bin/sh
# Release build -> build/SonosDrop.app -> /Applications. No Xcode, ad-hoc signature.
set -e
cd "$(dirname "$0")/.."
APP=build/SonosDrop.app
swift build -c release 2>&1 | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SonosDrop "$APP/Contents/MacOS/SonosDrop"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SonosDrop</string>
  <key>CFBundleIdentifier</key><string>com.jndrdlx.sonosdrop</string>
  <key>CFBundleName</key><string>SonosDrop</string>
  <key>CFBundleDisplayName</key><string>SonosDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>SonosDrop talks to your Sonos speakers and serves your music files to them.</string>
</dict></plist>
EOF
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
rm -rf /Applications/SonosDrop.app
cp -R "$APP" /Applications/SonosDrop.app
echo "Installed /Applications/SonosDrop.app"
```

Run: `chmod +x scripts/bundle.sh && make app`
Expected: `Installed /Applications/SonosDrop.app`. Then `open /Applications/SonosDrop.app` shows the menu bar icon with no dock icon.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonosDrop scripts/bundle.sh Makefile
git commit -m "feat: SwiftUI menu bar app and app bundle script

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

---

### Task 12: Manual integration pass against the Studio pair and README

**Files:**
- Create: `README.md`

Run each check with `/Applications/SonosDrop.app` open. Fix anything that fails in the unit that owns it (see file structure) and add a regression test where one is possible before committing the fix.

- [ ] **Step 1: Discovery**
  Popover lists "Studio" once (not twice, not 10.20.28.56). Refresh button repopulates. Clear the list by turning Wi-Fi off, click refresh: banner "No Sonos speakers found". Turn Wi-Fi on, enter `10.20.28.52` in the manual IP field, press return: Studio is back.

- [ ] **Step 2: Single file**
  Drop `~/Music/Bad Bunny/Un Verano Sin Ti/Bad Bunny - Moscow Mule.flac`. Within 3 s the speaker plays it, the row shows the green speaker icon, badge "FLAC 16/44.1", footer shows title, artist, elapsed counting up. Sonos iOS app shows title and artist too (DIDL metadata worked).

- [ ] **Step 3: Album folder**
  Drop the album folder. Rows appear sorted by file name, all `queued`, first one `playing`. Let the first track end: the speaker starts the second one on its own and the green icon moves down one row.

- [ ] **Step 4: Transport and volume**
  Pause, play, next, previous each take effect within a second. Volume slider moves both Fives. Sonos iOS app volume change is reflected in the slider within 1 s.

- [ ] **Step 5: Seeking**
  In the Sonos iOS app, scrub to the middle of the current track. Audio resumes there (Range requests work). Check with `log stream --predicate 'process == "SonosDrop"'` only if it fails.

- [ ] **Step 6: Unsupported file**
  Copy `Tests/SonosDropCoreTests/Fixtures/tone_24_96000.flac` to the Desktop and drop it together with one good FLAC. The hi-res row shows the orange triangle and "96 kHz, Sonos max is 48"; the good one plays.

- [ ] **Step 7: Sleep and wake**
  Close the lid for 2 minutes while playing, reopen. If the IP changed, the orange banner "Network changed, drop the files again to resend" appears and a new drop works. If the IP did not change, playback simply continues.

- [ ] **Step 8: Quit mid-track**
  Quit from the footer. The speaker keeps playing until its buffer runs out, then stops. Relaunch; popover comes back with Studio selected.

- [ ] **Step 9: Write README.md**

```markdown
# SonosDrop

Native macOS menu bar app that plays local audio files on a Sonos group. Drop files or a folder
on the popover; the app serves them over HTTP from your Mac and queues them on the speaker.

## Build (no Xcode needed)

    make test      # unit tests
    make app       # release build, bundle, ad-hoc sign, install to /Applications

Requires Command Line Tools with Swift 6.4 or newer on macOS 15 or newer.

## Notes

- Formats: MP3, AAC, FLAC, ALAC, WAV, AIFF, OGG, up to 24-bit/48 kHz stereo (Sonos limits).
  Anything above is listed with a reason and skipped.
- macOS asks once to allow incoming connections; the speaker pulls the files from this Mac.
- Commands always target the group coordinator, so stereo pairs appear once.
- If discovery finds nothing, use the network icon to enter a speaker IP by hand.
```

- [ ] **Step 10: Commit**

```bash
git add README.md
git commit -m "docs: README and manual integration checklist passed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEZwLYqtEGaVLvQawRrbnK"
```

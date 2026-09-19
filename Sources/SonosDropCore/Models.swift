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

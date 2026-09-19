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

# SonosDrop — native macOS menu bar app for streaming local files to Sonos

Date: 2026-09-19
Status: approved design, v1 scope

## Problem

The official Sonos macOS app is unusable on this machine. The user has local FLAC/MP3
files and a Sonos S2 system (two Sonos Five as a stereo pair named "Studio",
coordinator 10.20.28.52, secondary 10.20.28.56, firmware 97.1). They need a small,
dependency-free native app that plays dropped files on a chosen speaker group.

Proven on this network with soco-cli: serve a file over plain HTTP from the Mac
(10.20.28.66) and hand the URL to the coordinator via UPnP AVTransport. Sonos pulls
the file and plays it.

## Scope (v1)

In:
- Menu bar app (`MenuBarExtra`), no dock icon, no main window.
- Discover Sonos groups on the LAN; pick one.
- Drag files or folders onto the popover; tracks are inspected, queued on the speaker
  in drop order, and playback starts.
- Transport: play/pause, next, previous, volume slider. Now-playing title, artist,
  elapsed/duration.
- Unsupported files stay visible with a reason badge and are not sent.
- Build and install from the terminal with no Xcode: `make app`.

Out (v2 candidates): transcoding, launch at login, library browsing, multiple groups
at once, playlists, artwork, notarization.

## Constraints

- Toolchain: Swift 6.4 Command Line Tools only, macOS 27. No Xcode, no third-party
  packages. Foundation, Network, AudioToolbox, SwiftUI only.
- Sonos playable formats: MP3, AAC (M4A/MP4), FLAC, ALAC, WAV, AIFF, OGG Vorbis.
  Maximum 24-bit / 48 kHz, stereo.
- Sonos needs HTTP/1.1 with `Content-Length`, correct `Content-Type`, and byte-range
  support (`Range: bytes=a-b`) to seek and to probe FLAC headers.
- Group commands must go to the group coordinator, never a stereo-pair secondary.

## Architecture

Swift package `SonosDrop` with one executable target and one test target.

```
Sources/SonosDrop/
  SonosDropApp.swift      @main, MenuBarExtra, wires QueueModel
  Discovery.swift         SSDP search + ZoneGroupTopology parse -> [SpeakerGroup]
  SonosClient.swift       SOAP actions against a coordinator IP
  DIDL.swift              DIDL-Lite metadata builder + XML escaping
  MediaServer.swift       HTTP/1.1 file server on Network.framework, range support
  TrackInspector.swift    AudioToolbox probe -> Track (format, tags, playability)
  QueueModel.swift        @Observable app state; the only thing views touch
  MenuBarView.swift       popover UI
Tests/SonosDropTests/
  DIDLTests, RangeParserTests, SSDPParserTests, TrackInspectorTests (+ fixtures)
Makefile                  build, test, app (bundle + ad-hoc sign + install)
```

### Discovery

- Send `M-SEARCH * HTTP/1.1` to 239.255.255.250:1900 with
  `ST: urn:schemas-upnp-org:device:ZonePlayer:1`, listen 3 s for replies, collect
  `LOCATION` hosts. Fallback: if nothing replies, allow a manual IP entry.
- Call `ZoneGroupTopology#GetZoneGroupState` on the first host. Parse `ZoneGroup`
  elements into `SpeakerGroup { coordinatorUUID, coordinatorIP, name, memberIPs }`.
  Name is the coordinator's `ZoneName`; if a group has >1 distinct zone names, join
  with " + ". Stereo pairs share one `ZoneName` and collapse naturally.
- Members marked `Invisible="1"` are ignored for naming.
- Re-run on popover open if the list is older than 60 s, and on demand.

### SonosClient

SOAP over `URLSession` to `http://<ip>:1400/MediaRenderer/AVTransport/Control` and
`.../RenderingControl/Control`. Actions used:

| Action | Service | Purpose |
|---|---|---|
| RemoveAllTracksFromQueue | AVTransport | clear before a new drop |
| AddURIToQueue | AVTransport | one call per playable track, with DIDL metadata |
| SetAVTransportURI | AVTransport | point transport at `x-rincon-queue:<UUID>#0` |
| Seek (TRACK_NR) | AVTransport | jump to first queued track |
| Play / Pause / Next / Previous | AVTransport | transport |
| GetPositionInfo | AVTransport | poll every 1 s while popover is open |
| GetTransportInfo | AVTransport | PLAYING / PAUSED / STOPPED |
| GetVolume / SetVolume | RenderingControl | group volume via coordinator |

Errors: HTTP non-200 or SOAP `UPnPError` → `SonosError.upnp(code)`; timeouts (5 s) →
`SonosError.unreachable`. Responses are parsed with `XMLParser`; only the needed
elements are read.

### DIDL

Builds the `DIDL-Lite` string for `AddURIToQueue`:
`<item id="t/<token>" parentID="-1" restricted="true"><dc:title/><dc:creator/>
<upnp:album/><upnp:class>object.item.audioItem.musicTrack</upnp:class>
<res protocolInfo="http-get:*:<mime>:*" duration="H:MM:SS">url</res></item>`.
All text is XML-escaped; the whole document is escaped again when embedded in the
SOAP body. Unit-tested against a known-good string.

### MediaServer

- `NWListener` on TCP, port 0 (OS picks), IPv4, all interfaces. Exposes `baseURL`
  using the Mac's primary LAN IPv4 (first non-loopback `en*` interface with an IPv4).
- Routes: `GET|HEAD /t/<token>`. Token is 16 random bytes, hex. Unknown token → 404.
  Anything else → 404. No directory listing, no path handling.
- Response: `200` with `Content-Type`, `Content-Length`, `Accept-Ranges: bytes`;
  or `206` with `Content-Range` for a single byte range; `416` if unsatisfiable.
  Streams with `FileHandle` in 256 KB chunks; closes connection after response
  (`Connection: close`), which Sonos accepts.
- Range parser is a pure function `parseRange(header:fileSize:) -> Range<Int>?`,
  unit-tested.
- Restarts on `NWPathMonitor` change (new IP after sleep/network switch); QueueModel
  is told and marks the queue as "needs re-send".

### TrackInspector

- `AudioFileOpenURL` + `kAudioFilePropertyDataFormat` (sample rate, bits, channels,
  format ID), `kAudioFilePropertyEstimatedDuration`, `kAudioFilePropertyInfoDictionary`
  (title, artist, album). Runs off the main actor.
- Produces `Track { id, url, title, artist, album, duration, sampleRate, bitDepth,
  channels, mime, status }` where `status` is `.ready`, `.unsupported(reason)`,
  `.queued`, `.playing`, `.failed(reason)`.
- Rules: extension not in {mp3, m4a, mp4, aac, flac, wav, aif, aiff, ogg} →
  unsupported "format"; sampleRate > 48000 → "<rate> kHz, Sonos max is 48";
  bitDepth > 24 → "…bit, Sonos max is 24"; channels > 2 → "multichannel";
  unreadable → "can't read file". Fallback title is the file name.
- Folders are walked one level deep, sorted by file name; hidden files skipped.

### QueueModel (@Observable, @MainActor)

State: `groups`, `selectedGroup`, `tracks`, `nowPlaying` (title, artist, elapsed,
duration, state), `volume`, `serverStatus`, `lastError`.

`drop(urls:)` → inspect → register playable tracks with MediaServer → on the selected
coordinator: clear queue, add each, set transport to the queue, seek to 1, play.
Any failure sets `lastError` and marks affected tracks `.failed`.

Polling runs only while the popover is open.

### MenuBarView

Popover ~320×480. Top: group picker (Menu) with refresh. Middle: drop zone that
becomes the track list once populated; each row shows title, artist, format badge
("FLAC 16/44.1") and status badge. Bottom: now-playing line, transport buttons,
volume slider, error banner when `lastError` is set. Quit in a footer menu.

## Error handling summary

| Situation | Behaviour |
|---|---|
| No speakers found | Empty picker with "Search again" and manual IP field |
| Coordinator unreachable | Group greyed, transport disabled, error banner |
| Unsupported file | Row kept with reason badge, never sent |
| Sonos rejects AddURIToQueue | Row `.failed(UPnP <code>)`, continue with others |
| Mac IP changed | Server rebinds, banner "Network changed, drop again to resend" |
| Firewall prompt | One-time explanation text under the drop zone |

## Testing

Unit (swift test): DIDL builder output, range parser edge cases (open-ended, suffix,
out of bounds), SSDP/topology parser on captured XML from this network, TrackInspector
on three fixtures (16/44.1 FLAC, 24/96 FLAC, MP3).

Manual against the Studio pair: drop one FLAC plays; drop album advances tracks
without the app; pause/next/volume; seek from the Sonos iOS app works (range);
24/96 file shows badge and is skipped; sleep Mac 2 min, wake, banner appears;
quit app mid-track, speaker stops at end of buffered data.

## Build and distribution

`make test` → `swift test`. `make app` → `swift build -c release`, creates
`build/SonosDrop.app/Contents/{MacOS,Resources}`, writes `Info.plist` with
`LSUIElement=true`, bundle id `com.jndrdlx.sonosdrop`, `codesign --sign -`, copies to
`/Applications`. First launch triggers the macOS incoming-connections prompt.

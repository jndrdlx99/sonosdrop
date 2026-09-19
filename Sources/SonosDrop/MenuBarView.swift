import SwiftUI
import AppKit
import SonosDropCore

@Observable
final class MenuBarUIState {
    var showManualIP = false
}

struct MenuBarView: View {
    let model: QueueModel
    let ui: MenuBarUIState

    /// Opens a standard macOS open panel and hands the chosen URLs to the same path a drag-and-drop uses.
    /// The menu bar popover closes when a drag starts from Finder, so a picker is the reliable route.
    private func pickAndDrop(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        panel.title = folders ? "Choose a folder to play" : "Choose songs to play"
        panel.prompt = "Play"
        if !folders {
            panel.allowedContentTypes = [.audio]
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in await model.drop(urls) }
        }
    }

    private var pickerButtons: some View {
        HStack(spacing: 8) {
            Button { pickAndDrop(folders: true) } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
            Button { pickAndDrop(folders: false) } label: { Label("Add Files…", systemImage: "music.note.list") }
        }
        .controlSize(.small)
        .disabled(model.selectedGroup == nil || model.isBusy)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.tracks.isEmpty { dropZone } else { trackList }
            Divider()
            footer
        }
        .onAppear {
            model.startPolling()
            Task { await model.refreshIfStale() }
        }
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
                Picker("Speaker", selection: Binding(get: { model.selectedGroup }, set: { model.selectedGroup = $0 })) {
                    if model.groups.isEmpty { Text("No speakers").tag(SpeakerGroup?.none) }
                    ForEach(model.groups) { g in
                        if g.id == model.selectedGroup?.id && !model.coordinatorReachable {
                            Text("\(g.name) (unreachable)").foregroundStyle(.secondary).tag(Optional(g))
                        } else {
                            Text(g.name).tag(Optional(g))
                        }
                    }
                }
                .labelsHidden()
                Button { Task { await model.refreshGroups() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                    .help("Search for speakers again")
                Button { ui.showManualIP.toggle() } label: { Image(systemName: "network") }
                    .buttonStyle(.borderless)
                    .help("Enter a speaker IP manually")
                Button { pickAndDrop(folders: true) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .disabled(model.selectedGroup == nil || model.isBusy)
                    .help("Play a folder")
            }
            if ui.showManualIP {
                TextField("Speaker IP, e.g. 192.168.1.52", text: Binding(get: { model.manualIP }, set: { model.manualIP = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refreshGroups() }; ui.showManualIP = false }
            }
        }
        .padding(10)
    }

    // MARK: body

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Drop songs or a folder here").font(.headline)
            pickerButtons.padding(.vertical, 4)
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

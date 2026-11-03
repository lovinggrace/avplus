import AppKit
import AVPlus
import SwiftUI
import UniformTypeIdentifiers

@main
struct AVPlusDemoApp: App {
    init() {
        // Running from `swift run` has no bundle, so become a regular foreground app explicitly.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("AVPlus Demo") {
            PlayerScreen(initialURL: CommandLine.arguments.dropFirst().first.map(Self.url(from:)))
                .frame(minWidth: 640, minHeight: 420)
        }
    }

    private static func url(from argument: String) -> URL {
        if let url = URL(string: argument), url.scheme != nil { return url }
        return URL(filePath: argument)
    }
}

struct PlayerScreen: View {
    let initialURL: URL?

    @State private var player = AVPlusPlayer()
    @State private var isImporting = false
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            // `.none` gives AVFoundation and mpv the same look; the custom controls below drive both.
            AVPlusPlayerView(player: player, controls: .none)
            controls.padding(12)
        }
        .task {
            if let initialURL { await player.load(initialURL) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie, .audiovisualContent, .data]) { result in
            guard case let .success(url) = result else { return }
            Task { await player.load(url) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlayPause()
                }
                .labelStyle(.iconOnly)

                Text(format(scrubTime ?? player.currentTime)).monospacedDigit()
                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration ?? 1, 1)
                ) { editing in
                    if !editing, let target = scrubTime {
                        Task {
                            await player.seek(to: target)
                            scrubTime = nil
                        }
                    }
                }
                Text(format(player.duration ?? 0)).monospacedDigit()
            }

            HStack {
                Picker("Audio", selection: Binding(
                    get: { player.selectedAudioTrackID },
                    set: { id in player.selectAudioTrack(player.audioTracks.first { $0.id == id }) }
                )) {
                    ForEach(player.audioTracks) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .disabled(player.audioTracks.isEmpty)

                Picker("Subtitles", selection: Binding(
                    get: { player.selectedSubtitleTrackID },
                    set: { id in player.selectSubtitleTrack(player.subtitleTracks.first { $0.id == id }) }
                )) {
                    Text("Off").tag(String?.none)
                    ForEach(player.subtitleTracks) { Text($0.displayName).tag(Optional($0.id)) }
                }

                Picker("Speed", selection: $player.rate) {
                    ForEach([0.5, 1, 1.5, 2] as [Float], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }
                .frame(width: 140)

                Spacer()
                Text(statusText).foregroundStyle(.secondary)
                Button("Open…") { isImporting = true }
            }
        }
    }

    private var statusText: String {
        let backend = player.backend.map { $0 == .mpv ? "mpv" : "AVFoundation" } ?? "—"
        switch player.status {
        case let .failed(error): return "\(backend) · \(error.message)"
        default: return "\(backend) · \(player.isBuffering ? "buffering" : String(describing: player.status))"
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: .minuteSecond))
    }
}

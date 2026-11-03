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
    @State private var importing: ImportKind?
    @State private var scrubTime: Double?
    @State private var errorMessage: String?

    private enum ImportKind {
        case media
        case subtitles

        var contentTypes: [UTType] {
            switch self {
            case .media: [.movie, .audiovisualContent, .data]
            case .subtitles: ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // `.none` gives AVFoundation and mpv the same look; the custom controls below drive both.
            AVPlusPlayerView(player: player, controls: .none)
            controls.padding(12)
        }
        .task {
            if let initialURL { await player.load(initialURL) }
        }
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing?.contentTypes ?? []
        ) { [importing] result in
            guard case let .success(url) = result else { return }
            Task {
                switch importing {
                case .media: await player.load(url)
                case .subtitles: await addSubtitles(from: url)
                case nil: break
                }
            }
        }
        .alert("Could not add subtitles", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {} message: {
            Text(errorMessage ?? "")
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
                TrackPicker(player: player, kind: .audio)
                TrackPicker(player: player, kind: .subtitle)
                TrackSelectionMenu(player: player)
                    .labelStyle(.iconOnly)
                    .fixedSize()

                Picker("Speed", selection: $player.rate) {
                    ForEach([0.5, 1, 1.5, 2] as [Float], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }
                .frame(width: 140)

                Button("Remove", systemImage: "minus.circle") {
                    if let track = player.selectedSubtitleTrack { player.removeSubtitle(track) }
                }
                .labelStyle(.iconOnly)
                .disabled(player.selectedSubtitleTrack?.isExternal != true)
                .help("Remove the selected added subtitle track")

                Spacer()
                Text(statusText).foregroundStyle(.secondary)
                Button("Add Subtitles…") { importing = .subtitles }
                    .disabled(player.backend == nil)
                Button("Open…") { importing = .media }
            }
        }
    }

    /// Reads the file while the sandbox grants access, then hands the text to the player, so it
    /// keeps working after the security scope ends (mpv reads files lazily).
    private func addSubtitles(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            try await player.addSubtitle(
                text: text,
                format: SubtitleDocument.Format(pathExtension: url.pathExtension),
                title: url.deletingPathExtension().lastPathComponent
            )
        } catch {
            errorMessage = error.localizedDescription
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

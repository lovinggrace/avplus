import Combine
import CoreGraphics
import Foundation
import Libmpv
#if canImport(UIKit)
import UIKit
#endif

/// Plays media through libmpv (MPVKit), rendering into ``MPVMetalLayer``.
@MainActor
final class MPVEngine: PlaybackEngine {
    let backend = PlaybackBackend.mpv
    var eventHandler: ((EngineEvent) -> Void)?

    /// The layer mpv draws into. Hosted by `MPVVideoSurface`.
    let videoLayer = MPVMetalLayer()

    private let handle: MPVHandle
    private var lifecycleCancellables: Set<AnyCancellable> = []

    private var isReady = false
    /// mpv's own user agent, restored when a load brings none.
    private var defaultUserAgent: String?
    /// `sub-add` only works once a file is loaded.
    private var pendingSubtitleCommands: [[String]] = []
    private var temporarySubtitleFiles: [URL] = []
    private var isPaused = true
    private var isAtEnd = false
    private var resizeTask: Task<Void, Never>?
    private var videoWidth: Int64?
    private var videoHeight: Int64?

    init(configuration: PlayerConfiguration) throws {
        var options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            ("idle", "yes"),
            // Stay on the last frame at EOF so the player can report `.ended` and seek back.
            ("keep-open", "yes"),
            ("osd-level", "0"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"),
            ("subs-match-os-language", "yes"),
            // Like AVFoundation: pick subtitles by language or the default flag, never just any track.
            ("subs-fallback", "default"),
            // AVFoundation never picks up `movie.srt` next to `movie.mp4`; match it so both backends
            // only show sidecar subtitles added through `addSubtitle`. Override via `mpvOptions`.
            ("sub-auto", "no"),
            ("sub-visibility", configuration.subtitleRendering == .native ? "yes" : "no"),
        ]
        options += configuration.mpvOptions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        let windowID = Int64(Int(bitPattern: Unmanaged.passUnretained(videoLayer).toOpaque()))
        let owner = WeakOwner()
        handle = try MPVHandle(options: options, windowID: windowID) { events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    owner.engine?.handle(events)
                }
            }
        }
        owner.engine = self
        videoLayer.onResize = { owner.engine?.surfaceDidResize() }

        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("duration", MPV_FORMAT_DOUBLE),
            ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG),
            ("speed", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE),
            ("mute", MPV_FORMAT_FLAG),
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("track-list", MPV_FORMAT_STRING),
            ("sub-text", MPV_FORMAT_STRING),
        ]
        for (name, format) in observed {
            handle.observe(name, format: format)
        }
        observeApplicationLifecycle()
    }

    // MARK: - PlaybackEngine

    func load(url: URL, headers: HTTPHeaders, startTime: TimeInterval?, autoplay: Bool) {
        apply(headers)
        isReady = false
        isAtEnd = false
        pendingSubtitleCommands = []
        removeTemporarySubtitleFiles()
        handle.set("pause", flag: !autoplay)
        let target = url.isFileURL ? url.path : url.absoluteString
        var command = ["loadfile", target, "replace"]
        if let startTime, startTime > 0 {
            // loadfile <url> <flags> <index> <options>; per-file options do not leak into later loads.
            command += ["-1", "start=\(startTime)"]
        }
        emit(.status(.loading))
        emit(.subtitleCues([]))
        let status = handle.command(command)
        if status < 0 {
            emit(.failed(PlaybackError(Self.describe(status), backend: .mpv), beforeReady: true))
        }
    }

    /// Sets the request headers for the next load, and clears those of the previous one. mpv hands
    /// them to FFmpeg, which sends them with every request of a stream.
    private func apply(_ headers: HTTPHeaders) {
        if defaultUserAgent == nil { defaultUserAgent = handle.string("user-agent") ?? "" }
        handle.set("user-agent", string: headers.userAgent ?? defaultUserAgent ?? "")
        handle.set("referrer", string: headers.referer ?? "")
        // `change-list` takes one item as it is, so values may contain commas.
        handle.command(["change-list", "http-header-fields", "clr", ""])
        for field in headers.others {
            handle.command(["change-list", "http-header-fields", "append", "\(field.name): \(field.value)"])
        }
    }

    func play() {
        if isAtEnd {
            handle.command(["seek", "0", "absolute"])
        }
        handle.set("pause", flag: false)
    }

    func pause() {
        handle.set("pause", flag: true)
    }

    func seek(to time: TimeInterval, precise: Bool) async -> Bool {
        emit(.currentTime(time))
        let status = handle.command(["seek", String(max(0, time)), precise ? "absolute+exact" : "absolute"])
        return status >= 0
    }

    func setRate(_ rate: Float) {
        handle.set("speed", double: Double(rate))
    }

    func setVolume(_ volume: Float) {
        handle.set("volume", double: Double(min(max(volume, 0), 1)) * 100)
    }

    func setMuted(_ muted: Bool) {
        handle.set("mute", flag: muted)
    }

    func selectAudioTrack(id: String?) {
        handle.set("aid", string: id ?? "no")
    }

    func selectSubtitleTrack(id: String?) {
        handle.set("sid", string: id ?? "no")
        if id == nil { emit(.subtitleCues([])) }
    }

    func addExternalSubtitle(_ source: SubtitleSource, title: String, language: String?, select: Bool) async throws -> String? {
        let target: String
        switch source {
        case let .url(url):
            target = url.isFileURL ? url.path : url.absoluteString
        case let .text(text, format):
            target = try writeTemporarySubtitle(text, format: format).path
        }
        var command = ["sub-add", target, select ? "select" : "auto", title]
        if let language {
            command.append(language)
        }
        guard isReady else {
            pendingSubtitleCommands.append(command)
            return nil
        }
        // `sub-add` loads the file synchronously, so the new track is in `track-list` afterwards.
        let status = handle.command(command)
        if status < 0 {
            throw PlaybackError("Could not add subtitle: \(Self.describe(status))", backend: .mpv)
        }
        let tracks = handle.string("track-list").flatMap { try? MPVTrackList(json: $0) }
        let newest = tracks?.entries.filter { $0.type == "sub" && $0.external == true }.map(\.id).max()
        return newest.map(String.init)
    }

    func removeExternalSubtitle(id: String) {
        handle.command(["sub-remove", id])
    }

    /// mpv only reads subtitles from files or URLs, so in-memory text goes through a temp file.
    private func writeTemporarySubtitle(_ text: String, format: SubtitleDocument.Format) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AVPlus-Subtitles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        try Data(text.utf8).write(to: file)
        temporarySubtitleFiles.append(file)
        return file
    }

    private func removeTemporarySubtitleFiles() {
        for file in temporarySubtitleFiles {
            try? FileManager.default.removeItem(at: file)
        }
        temporarySubtitleFiles = []
    }

    /// Runs a raw mpv command, e.g. `["cycle", "deinterlace"]`. Returns the mpv status code.
    @discardableResult
    func command(_ arguments: [String]) -> Int32 {
        handle.command(arguments)
    }

    /// Makes mpv draw for the layer's new size.
    ///
    /// mpv's MoltenVK output reads the layer's size only when it configures itself for a video; it
    /// has no notion of the layer changing size later. After a rotation or a window resize it
    /// would keep laying the picture out for the old size: squashed, or small in a corner. The
    /// output is configured again whenever the video's parameters change, so the aspect ratio is
    /// changed by a hair and put back.
    private func surfaceDidResize() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            // Once the size has settled, not for every step of an animation or a window drag.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let width = self.videoWidth, let height = self.videoHeight,
                  width > 0, height > 0 else { return }
            let original = self.handle.string("video-aspect-override") ?? "-1"
            self.handle.set("video-aspect-override", string: String(format: "%.6f", Double(width + 2) / Double(height)))
            try? await Task.sleep(for: .milliseconds(150))
            self.handle.set("video-aspect-override", string: original)
        }
    }

    /// The video frame on screen, without subtitles. `nil` before a frame has been shown.
    func currentFrame() -> CGImage? {
        #if targetEnvironment(simulator)
        // Reading a frame back from the simulator's Metal driver crashes inside MoltenVK.
        return nil
        #else
        return handle.currentFrame()
        #endif
    }

    /// Sets a raw mpv property from its string representation.
    func setProperty(_ name: String, value: String) {
        handle.set(name, string: value)
    }

    deinit {
        // `shutdown()` is the normal path; this covers players released without it.
        handle.destroy(keepAlive: videoLayer)
    }

    func shutdown() {
        eventHandler = nil
        lifecycleCancellables.removeAll()
        videoLayer.removeFromSuperlayer()
        handle.destroy(keepAlive: videoLayer)
        removeTemporarySubtitleFiles()
    }

    // MARK: - Events

    private func handle(_ events: [MPVHandle.Event]) {
        for event in events {
            switch event {
            case let .property(name, value):
                handleProperty(name, value)
            case let .subtitle(text, start, end):
                let lines = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                emit(.subtitleCues(lines.isEmpty ? [] : [SubtitleCue(text: lines, start: start, end: end)]))
            case .fileLoaded:
                isReady = true
                pendingSubtitleCommands.forEach { handle.command($0) }
                pendingSubtitleCommands = []
                updateStatus()
            case .playbackRestart:
                emit(.buffering(false))
            case let .endFile(error):
                emit(.failed(PlaybackError(error ?? "Playback failed", backend: .mpv), beforeReady: !isReady))
            }
        }
    }

    private func handleProperty(_ name: String, _ value: MPVHandle.Value) {
        switch (name, value) {
        case let ("time-pos", .double(time)):
            emit(.currentTime(time))
        case let ("duration", .double(duration)):
            emit(.duration(duration))
        case ("duration", _):
            emit(.duration(nil))
        case let ("demuxer-cache-time", .double(time)):
            emit(.bufferedTime(time))
        case let ("pause", .flag(paused)):
            isPaused = paused
            updateStatus()
        case let ("paused-for-cache", .flag(buffering)):
            emit(.buffering(buffering))
        case let ("eof-reached", .flag(atEnd)):
            isAtEnd = atEnd
            updateStatus()
        case let ("speed", .double(speed)):
            emit(.rate(Float(speed)))
        case let ("volume", .double(volume)):
            emit(.volume(Float(volume / 100)))
        case let ("mute", .flag(muted)):
            emit(.muted(muted))
        case let ("dwidth", .int(width)):
            videoWidth = width
            emitVideoSize()
        case let ("dheight", .int(height)):
            videoHeight = height
            emitVideoSize()
        case ("dwidth", _), ("dheight", _):
            videoWidth = nil
            emitVideoSize()
        case let ("track-list", .string(json)):
            guard let list = try? MPVTrackList(json: json) else { return }
            emit(.tracks(audio: list.audioTracks, subtitles: list.subtitleTracks))
            emit(.selectedAudioTrack(list.selectedAudioID))
            emit(.selectedSubtitleTrack(list.selectedSubtitleID))
        default:
            break
        }
    }

    private func updateStatus() {
        guard isReady else { return }
        if isAtEnd {
            emit(.status(.ended))
        } else {
            emit(.status(isPaused ? .paused : .playing))
        }
    }

    private func emitVideoSize() {
        if let videoWidth, let videoHeight, videoWidth > 0, videoHeight > 0 {
            emit(.videoSize(CGSize(width: Double(videoWidth), height: Double(videoHeight))))
        } else {
            emit(.videoSize(nil))
        }
    }

    private func emit(_ event: EngineEvent) {
        eventHandler?(event)
    }

    private static func describe(_ status: Int32) -> String {
        String(cString: mpv_error_string(status))
    }

    // MARK: - Lifecycle

    private func observeApplicationLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        // Disabling the video track while in the background avoids a black screen on return.
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handle.set("vid", string: "no") }
            .store(in: &lifecycleCancellables)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handle.set("vid", string: "auto") }
            .store(in: &lifecycleCancellables)
        #endif
    }
}

/// Lets the event callback reach the engine without retaining it. Only touched on the main actor.
@MainActor
private final class WeakOwner: Sendable {
    weak var engine: MPVEngine?
}

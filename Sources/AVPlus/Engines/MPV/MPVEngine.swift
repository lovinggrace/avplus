import Combine
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
    /// `sub-add` only works once a file is loaded.
    private var pendingSubtitleCommands: [[String]] = []
    private var isPaused = true
    private var isAtEnd = false
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
            ("subs-fallback", "yes"),
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

    func load(url: URL, startTime: TimeInterval?, autoplay: Bool) {
        isReady = false
        isAtEnd = false
        pendingSubtitleCommands = []
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

    func addExternalSubtitle(url: URL, title: String?, language: String?, select: Bool) async throws {
        let target = url.isFileURL ? url.path : url.absoluteString
        var command = ["sub-add", target, select ? "select" : "auto"]
        if title != nil || language != nil {
            command.append(title ?? url.deletingPathExtension().lastPathComponent)
        }
        if let language {
            command.append(language)
        }
        guard isReady else {
            pendingSubtitleCommands.append(command)
            return
        }
        let status = handle.command(command)
        if status < 0 {
            throw PlaybackError("Could not add subtitle: \(Self.describe(status))", backend: .mpv)
        }
    }

    /// Runs a raw mpv command, e.g. `["cycle", "deinterlace"]`. Returns the mpv status code.
    @discardableResult
    func command(_ arguments: [String]) -> Int32 {
        handle.command(arguments)
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

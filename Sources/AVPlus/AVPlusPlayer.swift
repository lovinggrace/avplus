import AVFoundation
import Foundation
import Observation

/// A single playback API over AVFoundation and mpv.
///
/// The player picks a backend per URL: AVFoundation when it can play the media, mpv otherwise
/// (see ``BackendSelection``). If AVFoundation fails before the media becomes ready, the player
/// retries in mpv. Every property is observable, so SwiftUI views update automatically.
///
/// ```swift
/// @State private var player = AVPlusPlayer()
///
/// var body: some View {
///     AVPlusPlayerView(player: player)
///         .task { await player.load(URL(string: "https://example.com/movie.mkv")!) }
/// }
/// ```
@MainActor
@Observable
public final class AVPlusPlayer {
    public let configuration: PlayerConfiguration

    /// The media currently loaded.
    public private(set) var url: URL?
    /// The backend playing the current media. `nil` before the first load and after ``stop()``.
    public private(set) var backend: PlaybackBackend?
    public private(set) var status: PlaybackStatus = .idle
    /// `true` while playback is stalled waiting for data.
    public private(set) var isBuffering = false
    public private(set) var currentTime: TimeInterval = 0
    /// `nil` while unknown or for live streams.
    public private(set) var duration: TimeInterval?
    /// How far the media is buffered, in seconds from the start.
    public private(set) var bufferedTime: TimeInterval?
    /// The natural size of the video, `nil` for audio-only media.
    public private(set) var videoSize: CGSize?

    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioTrackID: MediaTrack.ID?
    public private(set) var selectedSubtitleTrackID: MediaTrack.ID?

    /// The subtitle cues that should be on screen right now. Render them yourself, or use
    /// ``SubtitleOverlay``. Updated for both backends, regardless of ``SubtitleRendering``.
    public private(set) var subtitleCues: [SubtitleCue] = []

    /// Playback speed used while playing. `1` is normal speed.
    public var rate: Float {
        get { storedRate }
        set {
            storedRate = newValue
            engine?.setRate(newValue)
        }
    }

    /// Volume in `0...1`.
    public var volume: Float {
        get { storedVolume }
        set {
            storedVolume = min(max(newValue, 0), 1)
            engine?.setVolume(storedVolume)
        }
    }

    public var isMuted: Bool {
        get { storedMuted }
        set {
            storedMuted = newValue
            engine?.setMuted(newValue)
        }
    }

    public var isPlaying: Bool { status == .playing }
    public var selectedAudioTrack: MediaTrack? { audioTracks.first { $0.id == selectedAudioTrackID } }
    public var selectedSubtitleTrack: MediaTrack? { subtitleTracks.first { $0.id == selectedSubtitleTrackID } }

    /// The underlying `AVPlayer` while the AVFoundation backend is active, e.g. for
    /// Picture in Picture or AirPlay. Prefer the player's own API for playback control.
    public var avPlayer: AVPlayer? { (engine as? AVFoundationEngine)?.player }

    var mpvLayer: MPVMetalLayer? { (engine as? MPVEngine)?.videoLayer }

    private var engine: (any PlaybackEngine)?
    private var storedRate: Float = 1
    private var storedVolume: Float = 1
    private var storedMuted = false

    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var currentLoad: (url: URL, startTime: TimeInterval?, autoplay: Bool)?
    @ObservationIgnored private var externalSubtitles: [ExternalSubtitle] = []
    @ObservationIgnored private var isResolvingBackend = false

    /// Sidecar subtitles of the current media, replayed when the player falls back to mpv.
    private struct ExternalSubtitle {
        let id = UUID()
        var source: SubtitleSource
        var title: String
        var language: String?
        var select: Bool
        /// The engine's track ID, once known.
        var trackID: MediaTrack.ID?
    }

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - Loading

    /// Loads `url`, picking the backend according to ``PlayerConfiguration/backend``.
    ///
    /// Returns once the backend is chosen and loading has started; observe ``status`` for the
    /// outcome. Calling `load` again supersedes a load that is still resolving.
    public func load(_ url: URL, startTime: TimeInterval? = nil, autoplay: Bool = true) async {
        loadGeneration += 1
        let generation = loadGeneration
        resetMediaState()
        self.url = url
        currentLoad = (url, startTime, autoplay)
        externalSubtitles = []
        status = .loading
        isResolvingBackend = true

        let backend = await BackendResolver.resolve(
            url,
            selection: configuration.backend,
            probeTimeout: configuration.probeTimeout
        )
        guard generation == loadGeneration else { return }
        start(backend, url: url, startTime: startTime, autoplay: autoplay)
    }

    /// Stops playback and releases the backend.
    public func stop() {
        loadGeneration += 1
        isResolvingBackend = false
        engine?.shutdown()
        engine = nil
        backend = nil
        url = nil
        currentLoad = nil
        externalSubtitles = []
        resetMediaState()
        status = .idle
    }

    // MARK: - Transport

    public func play() {
        engine?.play()
    }

    public func pause() {
        engine?.pause()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Seeks to an absolute position. With `precise: false` the backend may snap to a keyframe,
    /// which is faster.
    @discardableResult
    public func seek(to time: TimeInterval, precise: Bool = false) async -> Bool {
        guard let engine else { return false }
        var target = max(0, time)
        if let duration { target = min(target, duration) }
        currentTime = target
        return await engine.seek(to: target, precise: precise)
    }

    /// Seeks relative to the current position, e.g. `skip(by: -10)`.
    @discardableResult
    public func skip(by interval: TimeInterval) async -> Bool {
        await seek(to: currentTime + interval)
    }

    // MARK: - Tracks

    public func selectAudioTrack(_ track: MediaTrack?) {
        selectedAudioTrackID = track?.id
        engine?.selectAudioTrack(id: track?.id)
    }

    /// Selects a subtitle track, or turns subtitles off with `nil`.
    public func selectSubtitleTrack(_ track: MediaTrack?) {
        selectedSubtitleTrackID = track?.id
        subtitleCues = []
        engine?.selectSubtitleTrack(id: track?.id)
    }

    /// Adds a sidecar subtitle file to the current media, e.g. a SubRip (`.srt`) or WebVTT (`.vtt`)
    /// file on disk or on a server. mpv additionally reads ASS/SSA and other text formats.
    ///
    /// Works before, during and after playback has started; call it any time after
    /// ``load(_:startTime:autoplay:)``. Without a telling extension, the format is detected
    /// from the contents.
    ///
    /// - Parameters:
    ///   - title: Shown in ``MediaTrack/displayName``. Defaults to the file name.
    ///   - language: A BCP 47 / ISO 639 code such as `"en"`.
    ///   - select: Makes the new track the active subtitle track.
    /// - Returns: The new track, or `nil` if the media is still opening; the track then appears in
    ///   ``subtitleTracks`` once it is ready.
    @discardableResult
    public func addSubtitle(
        url: URL,
        title: String? = nil,
        language: String? = nil,
        select: Bool = true
    ) async throws -> MediaTrack? {
        let title = title ?? url.deletingPathExtension().lastPathComponent
        return try await addSubtitle(.url(url), title: title, language: language, select: select)
    }

    /// Adds subtitles from SubRip or WebVTT text, e.g. downloaded from an API or generated by the
    /// app, to the current media.
    ///
    /// - Parameter format: `nil` detects the format from the text.
    /// - Returns: The new track, or `nil` if the media is still opening.
    /// - Throws: ``SubtitleDocument/ParseError`` when the format cannot be detected.
    @discardableResult
    public func addSubtitle(
        text: String,
        format: SubtitleDocument.Format? = nil,
        title: String? = nil,
        language: String? = nil,
        select: Bool = true
    ) async throws -> MediaTrack? {
        guard let format = format ?? SubtitleDocument.Format(detectingIn: text) else {
            throw SubtitleDocument.ParseError.unsupportedFormat("unrecognized text")
        }
        let title = title ?? language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Subtitles"
        return try await addSubtitle(.text(text, format: format), title: title, language: language, select: select)
    }

    /// Removes a subtitle track added with `addSubtitle`. Tracks embedded in the media cannot be
    /// removed; deselect them with `selectSubtitleTrack(nil)` instead.
    public func removeSubtitle(_ track: MediaTrack) {
        guard track.isExternal else { return }
        engine?.removeExternalSubtitle(id: track.id)
        externalSubtitles.removeAll { $0.trackID == track.id }
        subtitleTracks.removeAll { $0.id == track.id }
        if selectedSubtitleTrackID == track.id {
            selectedSubtitleTrackID = nil
            subtitleCues = []
        }
    }

    private func addSubtitle(_ source: SubtitleSource, title: String, language: String?, select: Bool) async throws -> MediaTrack? {
        guard currentLoad != nil else {
            throw PlaybackError("Load media before adding subtitles")
        }
        var subtitle = ExternalSubtitle(source: source, title: title, language: language, select: select)
        externalSubtitles.append(subtitle)
        // Applied by `start` once the backend has been chosen.
        guard let engine, !isResolvingBackend else { return nil }

        do {
            subtitle.trackID = try await engine.addExternalSubtitle(source, title: title, language: language, select: select)
        } catch {
            externalSubtitles.removeAll { $0.id == subtitle.id }
            throw error
        }
        guard let trackID = subtitle.trackID else { return nil }
        if let index = externalSubtitles.firstIndex(where: { $0.id == subtitle.id }) {
            externalSubtitles[index].trackID = trackID
        }
        if select {
            selectedSubtitleTrackID = trackID
        }
        return subtitleTracks.first { $0.id == trackID } ?? MediaTrack(
            id: trackID,
            kind: .subtitle,
            title: title,
            language: language,
            isExternal: true,
            codec: source.codec
        )
    }

    // MARK: - mpv passthrough

    /// Runs a raw mpv command (e.g. `["cycle-values", "video-aspect-override", "16:9", "-1"]`).
    /// Returns `false` if the mpv backend is not active or the command failed.
    @discardableResult
    public func mpvCommand(_ arguments: [String]) -> Bool {
        guard let engine = engine as? MPVEngine else { return false }
        return engine.command(arguments) >= 0
    }

    /// Sets a raw mpv property. Ignored unless the mpv backend is active.
    public func setMPVProperty(_ name: String, to value: String) {
        (engine as? MPVEngine)?.setProperty(name, value: value)
    }

    // MARK: - Engine management

    private func start(_ backend: PlaybackBackend, url: URL, startTime: TimeInterval?, autoplay: Bool) {
        isResolvingBackend = false
        let engine: any PlaybackEngine
        do {
            engine = try prepareEngine(for: backend)
        } catch {
            status = .failed(error as? PlaybackError ?? PlaybackError(error.localizedDescription, backend: backend))
            return
        }
        engine.load(url: url, startTime: startTime, autoplay: autoplay)

        for subtitle in externalSubtitles {
            Task {
                let trackID = try? await engine.addExternalSubtitle(
                    subtitle.source,
                    title: subtitle.title,
                    language: subtitle.language,
                    select: subtitle.select
                )
                if let index = externalSubtitles.firstIndex(where: { $0.id == subtitle.id }) {
                    externalSubtitles[index].trackID = trackID
                }
            }
        }
    }

    /// Reuses the current engine when the backend does not change.
    private func prepareEngine(for backend: PlaybackBackend) throws -> any PlaybackEngine {
        if let engine, engine.backend == backend {
            return engine
        }
        engine?.shutdown()
        engine = nil
        self.backend = nil

        let newEngine: any PlaybackEngine = switch backend {
        case .avFoundation:
            AVFoundationEngine(
                configuration: configuration,
                readyTimeout: shouldFallBackToMPV(from: .avFoundation) ? configuration.probeTimeout : nil
            )
        case .mpv: try MPVEngine(configuration: configuration)
        }
        let engineID = ObjectIdentifier(newEngine)
        newEngine.eventHandler = { [weak self] event in
            guard let self, let engine = self.engine, ObjectIdentifier(engine) == engineID else { return }
            self.handle(event)
        }
        newEngine.setRate(storedRate)
        newEngine.setVolume(storedVolume)
        newEngine.setMuted(storedMuted)

        engine = newEngine
        self.backend = backend
        return newEngine
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .status(newStatus):
            if status != newStatus { status = newStatus }
        case let .buffering(buffering):
            if isBuffering != buffering { isBuffering = buffering }
        case let .currentTime(time):
            currentTime = time
        case let .duration(newDuration):
            if duration != newDuration { duration = newDuration }
        case let .bufferedTime(time):
            bufferedTime = time
        case let .rate(newRate):
            if storedRate != newRate { storedRate = newRate }
        case let .volume(newVolume):
            if storedVolume != newVolume { storedVolume = newVolume }
        case let .muted(muted):
            if storedMuted != muted { storedMuted = muted }
        case let .videoSize(size):
            if videoSize != size { videoSize = size }
        case let .tracks(audio, subtitles):
            if audioTracks != audio { audioTracks = audio }
            if subtitleTracks != subtitles { subtitleTracks = subtitles }
        case let .selectedAudioTrack(id):
            if selectedAudioTrackID != id { selectedAudioTrackID = id }
        case let .selectedSubtitleTrack(id):
            if selectedSubtitleTrackID != id { selectedSubtitleTrackID = id }
        case let .subtitleCues(cues):
            // AVFoundation re-delivers identical cues; avoid needless view updates.
            if subtitleCues.map(\.text) != cues.map(\.text) {
                subtitleCues = cues
            }
        case let .failed(error, beforeReady):
            if beforeReady, let backend, shouldFallBackToMPV(from: backend), let currentLoad {
                resetMediaState()
                status = .loading
                start(.mpv, url: currentLoad.url, startTime: currentLoad.startTime, autoplay: currentLoad.autoplay)
            } else {
                status = .failed(error)
            }
        }
    }

    private func shouldFallBackToMPV(from backend: PlaybackBackend) -> Bool {
        configuration.backend == .automatic && configuration.fallsBackToMPVOnFailure && backend == .avFoundation
    }

    private func resetMediaState() {
        isBuffering = false
        currentTime = 0
        duration = nil
        bufferedTime = nil
        videoSize = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        subtitleCues = []
    }
}

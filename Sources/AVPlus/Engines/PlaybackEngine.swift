import CoreGraphics
import Foundation

/// State changes an engine reports to ``AVPlusPlayer``.
enum EngineEvent: Sendable {
    case status(PlaybackStatus)
    case buffering(Bool)
    case currentTime(TimeInterval)
    case duration(TimeInterval?)
    case bufferedTime(TimeInterval?)
    case rate(Float)
    case volume(Float)
    case muted(Bool)
    case videoSize(CGSize?)
    case tracks(audio: [MediaTrack], subtitles: [MediaTrack])
    case selectedAudioTrack(String?)
    case selectedSubtitleTrack(String?)
    case subtitleCues([SubtitleCue])
    /// The engine failed. `beforeReady` is `true` when the media never became playable,
    /// which lets the player retry with another backend.
    case failed(PlaybackError, beforeReady: Bool)
}

/// Where a sidecar subtitle comes from.
enum SubtitleSource: Sendable {
    case url(URL)
    case text(String, format: SubtitleDocument.Format)

    var codec: String {
        switch self {
        case let .url(url): url.pathExtension.lowercased()
        case let .text(_, format): format.fileExtension
        }
    }
}

/// Common surface implemented by every backend. All calls happen on the main actor.
@MainActor
protocol PlaybackEngine: AnyObject {
    var backend: PlaybackBackend { get }
    var eventHandler: ((EngineEvent) -> Void)? { get set }

    func load(url: URL, startTime: TimeInterval?, autoplay: Bool)
    func play()
    func pause()
    func seek(to time: TimeInterval, precise: Bool) async -> Bool
    func setRate(_ rate: Float)
    /// Volume in `0...1`.
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
    func selectAudioTrack(id: String?)
    func selectSubtitleTrack(id: String?)
    /// Adds a sidecar subtitle track and returns its ID, or `nil` if the engine had to defer it
    /// until the media is loaded (the track then shows up in a later `.tracks` event).
    func addExternalSubtitle(_ source: SubtitleSource, title: String, language: String?, select: Bool) async throws -> String?
    /// Removes a track added with `addExternalSubtitle`.
    func removeExternalSubtitle(id: String)
    /// Releases all resources. The engine is unusable afterwards.
    func shutdown()
}

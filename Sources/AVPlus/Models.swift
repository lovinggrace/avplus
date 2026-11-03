import CoreGraphics
import Foundation

/// The playback engine that is driving an ``AVPlusPlayer``.
public enum PlaybackBackend: String, Sendable, Hashable {
    /// `AVPlayer` (rendered through AVKit's `VideoPlayer` or an `AVPlayerLayer`).
    case avFoundation
    /// libmpv via MPVKit (rendered into a Metal layer through MoltenVK).
    case mpv
}

/// How the player decides which ``PlaybackBackend`` to use for a URL.
public enum BackendSelection: Sendable, Hashable {
    /// Use AVFoundation when it can play the media, otherwise fall back to mpv.
    case automatic
    /// Always use AVFoundation.
    case avFoundation
    /// Always use mpv.
    case mpv
}

/// Who draws subtitles on screen.
public enum SubtitleRendering: Sendable, Hashable {
    /// The engine's own subtitle rendering is suppressed; the app draws ``AVPlusPlayer/subtitleCues``.
    case client
    /// The engine draws subtitles into the video. Cues are still published for e.g. transcripts.
    case native
}

public enum PlaybackStatus: Sendable, Equatable {
    case idle
    case loading
    case paused
    case playing
    case ended
    case failed(PlaybackError)
}

public struct PlaybackError: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    public var backend: PlaybackBackend?

    public init(_ message: String, backend: PlaybackBackend? = nil) {
        self.message = message
        self.backend = backend
    }

    public var errorDescription: String? { message }
}

/// An audio or subtitle track, normalized across backends.
public struct MediaTrack: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case audio
        case subtitle
    }

    /// Opaque, backend-specific identifier. Pass it back to the player to select the track.
    public var id: String
    public var kind: Kind
    public var title: String?
    /// BCP 47 / ISO 639 language code when known.
    public var language: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// `true` for subtitles added with ``AVPlusPlayer/addSubtitle(url:title:language:select:)``.
    public var isExternal: Bool
    public var codec: String?

    public init(
        id: String,
        kind: Kind,
        title: String? = nil,
        language: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        codec: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.codec = codec
    }

    /// A human readable label built from the title and language.
    public var displayName: String {
        let languageName = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        switch (title, languageName) {
        case let (title?, language?) where !title.localizedCaseInsensitiveContains(language):
            return "\(title) (\(language))"
        case let (title?, _):
            return title
        case let (nil, language?):
            return language
        default:
            return "Track \(id)"
        }
    }
}

/// A subtitle line that is currently due for display.
public struct SubtitleCue: Identifiable, Sendable, Hashable {
    public var id: UUID
    /// The text with formatting stripped.
    public var text: String
    /// The text with basic styling (italic, bold, underline, color) when the source provides it.
    public var attributedText: AttributedString
    /// Presentation start in seconds, if the backend reports it.
    public var start: TimeInterval?
    /// Presentation end in seconds, if the backend reports it.
    public var end: TimeInterval?

    public init(
        id: UUID = UUID(),
        text: String,
        attributedText: AttributedString? = nil,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.attributedText = attributedText ?? AttributedString(text)
        self.start = start
        self.end = end
    }
}

/// Configuration applied to every load of an ``AVPlusPlayer``.
public struct PlayerConfiguration: Sendable {
    public var backend: BackendSelection
    public var subtitleRendering: SubtitleRendering
    /// With ``BackendSelection/automatic``, retry in mpv when AVFoundation fails before the item becomes ready.
    public var fallsBackToMPVOnFailure: Bool
    /// Upper bound for probing a URL with AVFoundation before giving up and using mpv. With
    /// ``fallsBackToMPVOnFailure``, also how long an `AVPlayerItem` may take to become ready.
    public var probeTimeout: Duration
    /// Additional mpv options set before `mpv_initialize`, e.g. `["profile": "fast"]`.
    public var mpvOptions: [String: String]
    /// How often the current time is published.
    public var timeUpdateInterval: TimeInterval

    public init(
        backend: BackendSelection = .automatic,
        subtitleRendering: SubtitleRendering = .client,
        fallsBackToMPVOnFailure: Bool = true,
        probeTimeout: Duration = .seconds(10),
        mpvOptions: [String: String] = [:],
        timeUpdateInterval: TimeInterval = 0.1
    ) {
        self.backend = backend
        self.subtitleRendering = subtitleRendering
        self.fallsBackToMPVOnFailure = fallsBackToMPVOnFailure
        self.probeTimeout = probeTimeout
        self.mpvOptions = mpvOptions
        self.timeUpdateInterval = timeUpdateInterval
    }
}

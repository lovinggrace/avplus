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
///
/// Both backends describe tracks the same way: `language` is a normalized BCP 47 code (`"en"`,
/// `"pt-BR"`, never mpv's `"eng"`), `title` is the track's own title metadata (not a name derived
/// from the language), and the accessibility flags come from AVFoundation media characteristics
/// or mpv's track flags.
public struct MediaTrack: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case audio
        case subtitle
    }

    /// Opaque, backend-specific identifier. Pass it back to the player to select the track.
    public var id: String
    public var kind: Kind
    /// The title stored in the media, if any.
    public var title: String?
    /// BCP 47 language code when known, e.g. `"en"` or `"zh-Hant"`.
    public var language: String?
    public var isDefault: Bool
    /// Subtitles that only cover foreign-language dialogue or signs.
    public var isForced: Bool
    /// Subtitles for the deaf and hard of hearing (SDH) or closed captions.
    public var isHearingImpaired: Bool
    /// Audio description for blind and low-vision viewers.
    public var isAudioDescription: Bool
    /// Subtitles transcribed on device by ``SubtitleGenerator``.
    public var isGenerated: Bool
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
        isHearingImpaired: Bool = false,
        isAudioDescription: Bool = false,
        isGenerated: Bool = false,
        isExternal: Bool = false,
        codec: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.language = Self.normalizedLanguageCode(language)
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isAudioDescription = isAudioDescription
        self.isGenerated = isGenerated
        self.isExternal = isExternal
        self.codec = codec
    }

    /// The language's name in the current locale, e.g. "German" for `"de"`.
    public var languageName: String? {
        language.flatMap { Locale.current.localizedString(forIdentifier: $0) ?? Locale.current.localizedString(forLanguageCode: $0) }
    }

    /// A human readable label built from the title and language. ``TrackGroup/label(for:)`` adds
    /// qualifiers (Forced, SDH) and tells apart tracks that would otherwise look the same.
    public var displayName: String {
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

    /// Normalizes ISO 639-1/-2 codes and BCP 47 tags: `"eng"` → `"en"`, `"ger"` → `"de"`,
    /// `"en_US"` → `"en-US"`. Undetermined codes (`"und"`) become `nil`.
    public static func normalizedLanguageCode(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        var subtags = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        var primary = subtags[0].lowercased()
        guard !["und", "mis", "mul", "zxx", "qaa"].contains(primary) else { return nil }
        primary = bibliographicLanguageCodes[primary] ?? primary
        if primary.count == 3, let alpha2 = Locale.Language(identifier: primary).languageCode?.identifier(.alpha2) {
            primary = alpha2
        }
        subtags[0] = primary
        return subtags.joined(separator: "-")
    }

    /// ISO 639-2/B codes (common in Matroska) that Foundation does not map; mapped to 639-2/T.
    private static let bibliographicLanguageCodes: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
        "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
        "tib": "bod", "wel": "cym",
    ]
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

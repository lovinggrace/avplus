import Foundation

/// Decodes mpv's `track-list` property, which mpv serializes as JSON when read as a string.
struct MPVTrackList: Sendable {
    struct Entry: Decodable, Sendable {
        var id: Int
        var type: String
        var title: String?
        var lang: String?
        var codec: String?
        var `default`: Bool?
        var forced: Bool?
        var external: Bool?
        var selected: Bool?
        var hearingImpaired: Bool?
        var visualImpaired: Bool?

        enum CodingKeys: String, CodingKey {
            case id, type, title, lang, codec, `default`, forced, external, selected
            case hearingImpaired = "hearing-impaired"
            case visualImpaired = "visual-impaired"
        }
    }

    var entries: [Entry]

    init(json: String) throws {
        entries = try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
    }

    var audioTracks: [MediaTrack] { tracks(ofType: "audio", kind: .audio) }
    var subtitleTracks: [MediaTrack] { tracks(ofType: "sub", kind: .subtitle) }

    var selectedAudioID: String? { entries.first { $0.type == "audio" && $0.selected == true }.map { String($0.id) } }
    var selectedSubtitleID: String? { entries.first { $0.type == "sub" && $0.selected == true }.map { String($0.id) } }

    private func tracks(ofType type: String, kind: MediaTrack.Kind) -> [MediaTrack] {
        entries.filter { $0.type == type }.map { entry in
            MediaTrack(
                id: String(entry.id),
                kind: kind,
                title: entry.title,
                language: entry.lang,
                isDefault: entry.default ?? false,
                isForced: entry.forced ?? false,
                isHearingImpaired: entry.hearingImpaired ?? false,
                isAudioDescription: entry.visualImpaired ?? false,
                isExternal: entry.external ?? false,
                codec: entry.codec
            )
        }
    }
}

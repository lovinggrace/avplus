import Foundation

/// The tracks of one kind and which of them is selected: the model behind track menus.
///
/// ```swift
/// ForEach(player.trackGroups) { group in
///     Section(group.title) {
///         ForEach(group.tracks) { track in
///             Button(group.label(for: track)) { player.select(track) }
///         }
///     }
/// }
/// ```
public struct TrackGroup: Identifiable, Sendable, Hashable {
    public var kind: MediaTrack.Kind
    public var tracks: [MediaTrack]
    public var selectedTrackID: MediaTrack.ID?

    public var id: MediaTrack.Kind { kind }

    public var selectedTrack: MediaTrack? {
        tracks.first { $0.id == selectedTrackID }
    }

    /// Subtitles can be turned off; one audio track always plays.
    public var allowsEmptySelection: Bool { kind == .subtitle }

    /// "Audio" or "Subtitles".
    public var title: String {
        switch kind {
        case .audio: "Audio"
        case .subtitle: "Subtitles"
        }
    }

    public init(kind: MediaTrack.Kind, tracks: [MediaTrack], selectedTrackID: MediaTrack.ID?) {
        self.kind = kind
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
    }

    /// A menu label for `track`: its display name plus qualifiers ("Forced", "SDH", "AD"),
    /// with the codec or position added when two tracks would otherwise read the same.
    public func label(for track: MediaTrack) -> String {
        let base = qualifiedName(for: track)
        let twins = tracks.filter { qualifiedName(for: $0) == base }
        guard twins.count > 1 else { return base }

        let codecs = twins.compactMap(\.codec)
        if let codec = track.codec, Set(codecs).count == twins.count {
            return "\(base) – \(codec.uppercased())"
        }
        let position = (twins.firstIndex { $0.id == track.id } ?? 0) + 1
        return "\(base) \(position)"
    }

    private func qualifiedName(for track: MediaTrack) -> String {
        let name: String
        if track.title == nil, track.language == nil {
            name = "Track \((tracks.firstIndex { $0.id == track.id } ?? 0) + 1)"
        } else {
            name = track.displayName
        }

        var qualifiers: [String] = []
        if track.isForced { qualifiers.append("Forced") }
        if track.isHearingImpaired { qualifiers.append("SDH") }
        if track.isAudioDescription { qualifiers.append("AD") }
        qualifiers.removeAll { name.localizedCaseInsensitiveContains($0) }
        return qualifiers.isEmpty ? name : "\(name) (\(qualifiers.joined(separator: ", ")))"
    }
}

extension AVPlusPlayer {
    /// The audio and subtitle groups of the current media, leaving out kinds without tracks.
    public var trackGroups: [TrackGroup] {
        MediaTrack.Kind.allCases.map(trackGroup(for:)).filter { !$0.tracks.isEmpty }
    }

    public func trackGroup(for kind: MediaTrack.Kind) -> TrackGroup {
        switch kind {
        case .audio: TrackGroup(kind: .audio, tracks: audioTracks, selectedTrackID: selectedAudioTrackID)
        case .subtitle: TrackGroup(kind: .subtitle, tracks: subtitleTracks, selectedTrackID: selectedSubtitleTrackID)
        }
    }

    public func tracks(of kind: MediaTrack.Kind) -> [MediaTrack] {
        trackGroup(for: kind).tracks
    }

    public func selectedTrack(of kind: MediaTrack.Kind) -> MediaTrack? {
        trackGroup(for: kind).selectedTrack
    }

    /// Selects an audio or subtitle track, whichever kind it is.
    public func select(_ track: MediaTrack) {
        switch track.kind {
        case .audio: selectAudioTrack(track)
        case .subtitle: selectSubtitleTrack(track)
        }
    }

    /// Turns subtitles off. Ignored for audio, which always plays a track.
    public func deselectTrack(of kind: MediaTrack.Kind) {
        guard trackGroup(for: kind).allowsEmptySelection else { return }
        selectSubtitleTrack(nil)
    }

    /// Selects the track with `id`, or deselects the kind for `nil`. Unknown IDs are ignored.
    public func selectTrack(id: MediaTrack.ID?, of kind: MediaTrack.Kind) {
        guard let id else {
            deselectTrack(of: kind)
            return
        }
        if let track = tracks(of: kind).first(where: { $0.id == id }) {
            select(track)
        }
    }
}

import SwiftUI

extension AVPlusPlayer {
    /// A binding to the selected track of `kind`, for SwiftUI pickers. `nil` means off.
    public func trackSelection(for kind: MediaTrack.Kind) -> Binding<MediaTrack.ID?> {
        Binding(
            get: { self.trackGroup(for: kind).selectedTrackID },
            set: { self.selectTrack(id: $0, of: kind) }
        )
    }
}

/// A picker for the audio or subtitle tracks of an ``AVPlusPlayer``, with an "Off" entry for
/// subtitles. Works the same for both backends.
///
/// ```swift
/// Form {
///     TrackPicker(player: player, kind: .audio)
///     TrackPicker(player: player, kind: .subtitle)
/// }
/// ```
public struct TrackPicker<PickerLabel: View>: View {
    private let player: AVPlusPlayer
    private let kind: MediaTrack.Kind
    private let label: PickerLabel

    public init(player: AVPlusPlayer, kind: MediaTrack.Kind, @ViewBuilder label: () -> PickerLabel) {
        self.player = player
        self.kind = kind
        self.label = label()
    }

    public var body: some View {
        let group = player.trackGroup(for: kind)
        Picker(selection: player.trackSelection(for: kind)) {
            TrackOptions(group: group)
        } label: {
            label
        }
        .disabled(group.tracks.isEmpty)
    }
}

extension TrackPicker where PickerLabel == Text {
    /// - Parameter title: Defaults to "Audio" or "Subtitles".
    public init(_ title: String? = nil, player: AVPlusPlayer, kind: MediaTrack.Kind) {
        self.init(player: player, kind: kind) {
            Text(title ?? player.trackGroup(for: kind).title)
        }
    }
}

/// A menu with a section per track kind, like the audio and subtitles menu of the system player.
/// Disabled while the media has no selectable tracks.
///
/// ```swift
/// TrackSelectionMenu(player: player)
/// ```
public struct TrackSelectionMenu<MenuLabel: View>: View {
    private let player: AVPlusPlayer
    private let kinds: [MediaTrack.Kind]
    private let label: MenuLabel

    public init(
        player: AVPlusPlayer,
        kinds: [MediaTrack.Kind] = MediaTrack.Kind.allCases,
        @ViewBuilder label: () -> MenuLabel
    ) {
        self.player = player
        self.kinds = kinds
        self.label = label()
    }

    public var body: some View {
        let groups = kinds.map(player.trackGroup(for:)).filter { !$0.tracks.isEmpty }
        Menu {
            ForEach(groups) { group in
                Picker(group.title, selection: player.trackSelection(for: group.kind)) {
                    TrackOptions(group: group)
                }
                .pickerStyle(.inline)
            }
        } label: {
            label
        }
        .disabled(groups.isEmpty)
    }
}

extension TrackSelectionMenu where MenuLabel == Label<Text, Image> {
    public init(player: AVPlusPlayer, kinds: [MediaTrack.Kind] = MediaTrack.Kind.allCases) {
        self.init(player: player, kinds: kinds) {
            Label("Audio & Subtitles", systemImage: "captions.bubble")
        }
    }
}

/// The tagged rows shared by ``TrackPicker`` and ``TrackSelectionMenu``.
private struct TrackOptions: View {
    let group: TrackGroup

    var body: some View {
        if group.allowsEmptySelection {
            Text("Off").tag(MediaTrack.ID?.none)
        }
        ForEach(group.tracks) { track in
            Text(group.label(for: track)).tag(Optional(track.id))
        }
    }
}

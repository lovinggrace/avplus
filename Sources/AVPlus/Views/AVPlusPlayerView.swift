import AVKit
import SwiftUI

/// Renders an ``AVPlusPlayer`` with whichever backend is active, plus a subtitle layer.
///
/// - AVFoundation media is shown in AVKit's `VideoPlayer` (``Controls/system``) or in a bare
///   `AVPlayerLayer` (``Controls/none``).
/// - mpv media is shown in a Metal layer. mpv has no system controls, so apps that want the same
///   look for every format should use ``Controls/none`` and draw their own controls.
///
/// The subtitle content is laid out over the visible video rectangle, not the letterbox.
public struct AVPlusPlayerView<SubtitleContent: View>: View {
    public enum Controls: Sendable {
        /// AVKit's playback controls when AVFoundation is active.
        case system
        /// Video only.
        case none
    }

    private let player: AVPlusPlayer
    private let controls: Controls
    private let subtitleContent: ([SubtitleCue]) -> SubtitleContent

    /// - Parameter subtitles: Builds the subtitle layer from the cues that are currently due.
    public init(
        player: AVPlusPlayer,
        controls: Controls = .system,
        @ViewBuilder subtitles: @escaping ([SubtitleCue]) -> SubtitleContent
    ) {
        self.player = player
        self.controls = controls
        self.subtitleContent = subtitles
    }

    public var body: some View {
        ZStack {
            Color.black
            video
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    @ViewBuilder
    private var video: some View {
        switch player.backend {
        case .avFoundation:
            if let avPlayer = player.avPlayer {
                switch controls {
                case .system:
                    VideoPlayer(player: avPlayer) { subtitleLayer }
                case .none:
                    AVPlayerLayerView(player: avPlayer).overlay { subtitleLayer }
                }
            }
        case .mpv:
            if let layer = player.mpvLayer {
                MPVVideoSurface(videoLayer: layer).overlay { subtitleLayer }
            }
        case nil:
            EmptyView()
        }
    }

    private var subtitleLayer: some View {
        VideoRect(videoSize: player.videoSize) {
            subtitleContent(player.subtitleCues)
        }
        .allowsHitTesting(false)
    }
}

extension AVPlusPlayerView where SubtitleContent == SubtitleOverlay {
    /// Uses ``SubtitleOverlay`` when ``SubtitleRendering/client`` is configured, and draws
    /// nothing when the backend renders subtitles itself.
    public init(player: AVPlusPlayer, controls: Controls = .system) {
        let showsCues = player.configuration.subtitleRendering == .client
        self.init(player: player, controls: controls) { cues in
            SubtitleOverlay(cues: showsCues ? cues : [])
        }
    }
}

/// Places its content in the aspect-fit rectangle of the video.
private struct VideoRect<Content: View>: View {
    let videoSize: CGSize?
    @ViewBuilder let content: Content

    var body: some View {
        if let videoSize, videoSize.width > 0, videoSize.height > 0 {
            Color.clear
                .aspectRatio(videoSize, contentMode: .fit)
                .overlay { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}

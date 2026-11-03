import AVFoundation
import Foundation

/// Decides whether AVFoundation can play a URL or whether mpv has to take over.
enum BackendResolver {
    /// Containers AVFoundation never plays; these skip probing entirely.
    static let mpvOnlyExtensions: Set<String> = [
        "mkv", "mk3d", "mka", "webm", "avi", "divx", "flv", "f4v", "wmv", "wma", "asf",
        "ogv", "ogm", "rm", "rmvb", "vob", "ts", "m2ts", "mts", "tp",
        "nut", "mxf", "ape", "wv", "amv", "iso", "bdmv",
    ]

    /// Formats AVFoundation streams itself; probing them before playback is wasteful or impossible.
    static let avStreamingExtensions: Set<String> = ["m3u8"]

    static let mpvOnlySchemes: Set<String> = ["rtsp", "rtmp", "rtmps", "smb", "ftp", "sftp", "udp", "rtp", "srt", "mms"]

    /// Fast decision from the URL alone. `nil` means the asset has to be probed.
    static func quickDecision(for url: URL) -> PlaybackBackend? {
        if let scheme = url.scheme?.lowercased(), mpvOnlySchemes.contains(scheme) {
            return .mpv
        }
        let ext = url.pathExtension.lowercased()
        if mpvOnlyExtensions.contains(ext) { return .mpv }
        if avStreamingExtensions.contains(ext) { return .avFoundation }
        return nil
    }

    static func resolve(_ url: URL, selection: BackendSelection, probeTimeout: Duration) async -> PlaybackBackend {
        switch selection {
        case .avFoundation: return .avFoundation
        case .mpv: return .mpv
        case .automatic: break
        }
        if let decision = quickDecision(for: url) { return decision }

        return await withTaskGroup(of: PlaybackBackend?.self) { group in
            group.addTask { await isPlayableByAVFoundation(url) ? .avFoundation : .mpv }
            group.addTask {
                try? await Task.sleep(for: probeTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .mpv
        }
    }

    /// `AVAsset.isPlayable` is `true` as soon as *any* track can be played, so a file with an
    /// AAC track and a VP9 video track would pass. Every video track has to be playable too.
    static func isPlayableByAVFoundation(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let (isPlayable, hasProtectedContent, tracks) = try await asset.load(.isPlayable, .hasProtectedContent, .tracks)
            guard isPlayable else { return false }
            // FairPlay content can only ever be handled by AVFoundation.
            if hasProtectedContent { return true }

            var hasPlayableAudio = false
            var hasAudio = false
            for track in tracks {
                let trackPlayable = try await track.load(.isPlayable)
                switch track.mediaType {
                case .video:
                    if !trackPlayable { return false }
                case .audio:
                    hasAudio = true
                    hasPlayableAudio = hasPlayableAudio || trackPlayable
                default:
                    break
                }
            }
            return !hasAudio || hasPlayableAudio
        } catch {
            return false
        }
    }
}

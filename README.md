# AVPlus

A SwiftUI façade over two playback engines:

- **AVFoundation** (`AVPlayer`, shown in AVKit's `VideoPlayer`) for everything Apple can play: MP4/MOV/M4V, HLS, FairPlay, and so on.
- **mpv** via [MPVKit](https://github.com/mpvkit/MPVKit) for everything else: MKV, WebM, AVI, FLV, VP9/AV1/Opus, ASS subtitles, RTSP, and more.

Apps get one observable player, one view and one subtitle model, whichever engine runs.

Platforms: iOS 17, macOS 14, tvOS 17 and visionOS 1.

## Installation

```swift
.package(url: "https://github.com/lovinggrace/avplus.git", branch: "main")
```

AVPlus depends on the LGPL `MPVKit` product. libmpv and FFmpeg are linked statically, so your app has to meet the LGPL's relinking obligations. To use the GPL build instead, switch the dependency in `Package.swift` to `MPVKit-GPL`.

## Usage

```swift
import AVPlus
import SwiftUI

struct PlayerScreen: View {
    @State private var player = AVPlusPlayer()

    var body: some View {
        AVPlusPlayerView(player: player)
            .task {
                await player.load(URL(string: "https://example.com/movie.mkv")!)
                try? await player.addSubtitle(url: URL(string: "https://example.com/movie.en.srt")!, language: "en")
            }
    }
}
```

### Unified API

| | |
|---|---|
| Loading | `load(_:startTime:autoplay:)`, `stop()` |
| Transport | `play()`, `pause()`, `togglePlayPause()`, `seek(to:precise:)`, `skip(by:)` |
| Settings | `rate`, `volume`, `isMuted` (read/write) |
| State | `status`, `isBuffering`, `currentTime`, `duration`, `bufferedTime`, `videoSize`, `backend` |
| Tracks | `audioTracks`, `subtitleTracks`, `selectAudioTrack(_:)`, `selectSubtitleTrack(_:)` |
| Sidecar subtitles | `addSubtitle(url:…)`, `addSubtitle(text:format:…)`, `removeSubtitle(_:)` |
| Subtitles | `subtitleCues`: the cues due on screen right now |
| Escape hatches | `avPlayer`, `mpvCommand(_:)`, `setMPVProperty(_:to:)` |

All properties are `@Observable`, so SwiftUI views update on their own.

### Choosing a backend

`PlayerConfiguration.backend` defaults to `.automatic`:

1. The URL decides when it can: `.mkv`, `.webm`, `.avi` and `rtsp://` go to mpv; `.m3u8` goes to AVFoundation.
2. Anything else is probed with `AVURLAsset`. Every video track has to be playable, plus at least one audio track if the file has any. (`AVAsset.isPlayable` on its own also accepts files where only the audio can be decoded.)
3. If the `AVPlayerItem` fails, or is not ready within `probeTimeout`, the player retries in mpv. Sidecar subtitles you added are carried over.

To pin an engine, pass `.avFoundation` or `.mpv`.

### Adding SRT or WebVTT subtitles

You can add subtitles to the media that's loaded at any point: before it starts, while it plays, or after it has ended. They work with both backends:

```swift
// A file on disk or on a server. If the URL has no .srt/.vtt extension, the format is detected from the content.
let english = try await player.addSubtitle(url: subtitleURL, title: "English", language: "en")

// Text you already have, e.g. from an API. The format is detected when `format` is nil.
let german = try await player.addSubtitle(text: vttString, format: .webVTT, language: "de", select: false)

player.selectSubtitleTrack(german)   // switch between tracks
player.removeSubtitle(english!)      // remove an added track
```

- New tracks appear in `subtitleTracks` with `isExternal == true`, and are selected unless you pass `select: false`.
- AVFoundation can't load sidecar subtitle files, so AVPlus parses SRT/WebVTT itself and keeps the cues in sync with playback. mpv loads them natively. In-memory text is handed to mpv through a temporary file.
- Both backends support the common inline styling: `<i>`, `<b>`, `<u>`, `<font color>`, WebVTT `<c>`/`<v>` and `{\i1}`-style overrides.
- In a sandboxed app, read files the user picked while you hold security-scoped access, then pass the text with `addSubtitle(text:)`. mpv opens files lazily, after that access may have ended. The demo app shows this.
- mpv's automatic loading of `movie.srt` next to `movie.mkv` is off (`sub-auto=no`), matching AVFoundation. To turn it back on, pass `mpvOptions: ["sub-auto": "exact"]`.

### Rendering subtitles yourself

With the default `SubtitleRendering.client`, both engines stop drawing subtitles and publish them as `SubtitleCue` values instead:

```swift
public struct SubtitleCue {
    var text: String                    // plain text
    var attributedText: AttributedString // italic, bold, underline and color when the source has them
    var start: TimeInterval?
    var end: TimeInterval?
}
```

You can draw them in any SwiftUI view:

```swift
AVPlusPlayerView(player: player, controls: .none) { cues in
    VStack {
        Spacer()
        ForEach(cues) { Text($0.attributedText).font(.title2).padding(6).background(.black.opacity(0.6)) }
    }
}
```

The subtitle layer is laid out over the visible video rectangle, not over the letterbox. `SubtitleOverlay` is the default renderer. You can also read `player.subtitleCues` anywhere else, for transcripts or a second screen.

Where the cues come from:

- **AVFoundation, embedded tracks (incl. CEA-608):** `AVPlayerItemLegibleOutput` with `suppressesPlayerRendering`. CoreMedia text markup is mapped to `AttributedString`.
- **AVFoundation, sidecar SRT/WebVTT:** parsed by `SubtitleDocument`, because AVPlayer cannot load sidecar files.
- **mpv:** the `sub-text`, `sub-start` and `sub-end` properties, with `sub-visibility=no`. This works for any text format mpv reads, ASS/SSA included. Bitmap subtitles (PGS, VobSub) have no text, so in client mode they produce no cues. Use `.native` for them.

With `SubtitleRendering.native`, the engines draw subtitles themselves and cues are still published.

### Controls

`AVPlusPlayerView(player:controls:)`:

- `.system` (the default) uses AVKit's `VideoPlayer` controls when AVFoundation is active.
- `.none` shows only the video.

mpv has no system controls. If every format should look the same, use `.none` and build your own controls from the player API. `Examples/AVPlusDemo` shows how.

## Demo

```bash
cd Examples/AVPlusDemo && swift run AVPlusDemo /path/to/video.mkv
```

## Notes

- mpv renders through MoltenVK (`vo=gpu-next`, `gpu-api=vulkan`), following MPVKit's demo. MPVKit warns that Metal support is still experimental. HDR content can trip Metal API validation in debug builds, so turn validation off in the scheme if that happens.
- Override mpv options with `PlayerConfiguration.mpvOptions`, for example `["profile": "fast", "hwdec": "auto-safe"]`.
- On iOS and tvOS, the mpv backend turns its video track off in the background and back on in the foreground. This avoids a black screen when the app returns.

## Tests

```bash
swift test
```

The tests cover subtitle parsing, mpv track-list decoding, backend routing, and real playback through both engines using the fixtures in `Tests/AVPlusTests/Fixtures`: an H.264/AAC MP4, a VP9/Opus/SRT MKV, and an SRT file.

# AVPlus

A SwiftUI façade over two playback engines:

- **AVFoundation** (`AVPlayer`, shown in AVKit's `VideoPlayer`) for everything Apple can play: MP4/MOV/M4V, HLS, FairPlay, and so on.
- **mpv** via [MPVKit](https://github.com/mpvkit/MPVKit) for everything else: MKV, WebM, AVI, FLV, VP9/AV1/Opus, ASS subtitles, RTSP, and more.

Apps get one observable player, one view and one subtitle model, whichever engine runs.

Platforms: iOS 26, macOS 26, tvOS 26 and visionOS 26. On-device subtitle generation needs SpeechAnalyzer, which these releases introduced.

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
| Tracks | `trackGroups`, `trackGroup(for:)`, `select(_:)`, `selectTrack(id:of:)`, `deselectTrack(of:)`, `trackSelection(for:)` (a SwiftUI `Binding`); per kind: `audioTracks`, `subtitleTracks`, `selectAudioTrack(_:)`, `selectSubtitleTrack(_:)` |
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

### Selecting audio and subtitle tracks

The player describes tracks the same way for both backends. For a drop-in menu like the system player's, use:

```swift
TrackSelectionMenu(player: player)                 // Audio and Subtitles sections, with checkmarks
TrackPicker(player: player, kind: .subtitle)       // a single picker, e.g. in a settings Form
```

To build your own UI, use `TrackGroup`:

```swift
ForEach(player.trackGroups) { group in             // only the kinds the media has
    Section(group.title) {
        if group.allowsEmptySelection {            // subtitles can be off; audio cannot
            Button("Off") { player.deselectTrack(of: group.kind) }
        }
        ForEach(group.tracks) { track in
            Button(group.label(for: track)) { player.select(track) }
                .bold(track.id == group.selectedTrackID)
        }
    }
}
```

What gets normalized, so both backends report the same thing for the same file:

- **Language:** `MediaTrack.language` is a BCP 47 code. mpv/Matroska's `eng` and `ger` become `en` and `de`, and `und` becomes `nil`. `languageName` gives the localized name.
- **Title:** `title` is only the title stored in the media. AVFoundation's language-derived display name is not used.
- **Flags:** `isForced`, `isHearingImpaired` (SDH/CC) and `isAudioDescription` come from AVFoundation media characteristics or mpv's track flags.
- **Forced twins:** AVFoundation adds a "Forced" copy of every MP4 subtitle track. These are hidden, so the list matches the tracks actually in the file. A real forced-only track stays.
- **Labels:** `TrackGroup.label(for:)` adds "Forced", "SDH" or "AD". When two tracks would read the same, it adds the codec or a number.
- **Automatic subtitles:** mpv only turns subtitles on automatically by language or the default flag (`subs-fallback=default`), like AVFoundation. It never picks just any track.

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

### Generating subtitles on device

AVPlus can transcribe a video's audio on device and turn the transcript into subtitles. The generated track works with both backends:

```swift
let generation = player.generateSubtitles(locale: Locale(identifier: "ja-JP"))

ProgressView(value: generation.progress)          // observable: phase, progress, cues, document
Button("Cancel") { generation.cancel() }

let document = try await generation.value()      // the finished SubtitleDocument
try document.write(to: movieURL.deletingPathExtension().appendingPathExtension("srt"))
```

- **The track shows up right away** (`isGenerated == true`) and fills in as sentences are recognized, so you can turn it on while transcription is still running.
- **Audio track:** the currently selected audio track is transcribed by default. Pass `audioTrack:` to pick another.
- **Caching:** finished transcripts go into `SubtitleStore.cache`, keyed by the file's path, size and modification date plus the language and audio track. Pass `store: .persistent` to keep them beyond cache purges, or `nil` to always transcribe.
- **Persistence:** `saveSubtitles(_:to:)` saves any generated or document track. On a later launch, `restoreSubtitles(from:)` adds the saved tracks back for that media, and `generateSubtitles` reuses a restored transcript instead of transcribing again.
- **Bring your own subtitles:** `addSubtitle(document:)` attaches any `SubtitleDocument` (parsed, generated or built in code) as a track. `subtitleDocument(for:)` gives the cues back, and `SubtitleDocument.export(as:)` / `write(to:)` produce SRT or WebVTT.

`SubtitleGenerator` is the same pipeline without a player, for batch jobs or exporting:

```swift
for try await event in SubtitleGenerator().events(for: url, options: .init(locale: Locale(identifier: "en-US"))) {
    switch event {
    case let .downloadingModel(progress): print("model", progress)
    case let .transcribing(progress): print("transcribing", progress)
    case let .cues(cues): print(cues.map(\.text))          // final cues, in order
    case let .finished(document, fromCache): print(document.export(as: .webVTT), fromCache)
    }
}
```

How it works:

1. **Decoding.** The selected audio track is decoded into timestamped PCM with `AVAssetReader`. Formats AVFoundation can't read, such as Matroska, WebM, Opus or Vorbis, fall back to the FFmpeg that ships with MPVKit. The decoder runs only as fast as the transcriber consumes audio, so a long movie is never held decoded in memory.
2. **Transcription.** `SpeechAnalyzer` with `SpeechTranscriber` (`attributeOptions: [.audioTimeRange]`) receives every buffer with its media-relative start time. Word timings are therefore on the same clock as `currentTime`, for both backends. The speech model is downloaded through `AssetInventory` when needed, with progress reported.
3. **Alignment.** The transcriber stretches the first word of each result back over the silence before it. A 10 ms loudness envelope of the decoded audio moves those starts forward to where speech actually begins, typically within 0.1 s of the audio.
4. **Sentences.** Words build up across recognition results, and `NLTokenizer(unit: .sentence)`, configured for English or Japanese, splits them into sentences. That covers sentences that span results and results that hold several sentences. When punctuation is missing:
   - a pause of 1.2 s or more ends a sentence;
   - text that grows past twice the cue limits is cut at the best boundary, weighing pauses, commas/読点 and balance;
   - long runs without spaces are split into words with interpolated times.
5. **Cue limits.** `SubtitleSegmentation` controls the size of each cue. The `.english` preset allows 84 characters, `.japanese` 32 characters, and both 7 seconds and at least 1 second per cue. You can pass your own.

Generation runs entirely on device. `SubtitleGenerator.supports(_:)` tells you whether a locale is available. Cancel by calling `cancel()`, or by cancelling the task that consumes `events`, which stops decoding and transcription.

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

The tests cover subtitle parsing, mpv track-list decoding, backend routing, and real playback through both engines using the fixtures in `Tests/AVPlusTests/Fixtures`: an H.264/AAC MP4, a VP9/Opus/SRT MKV, an SRT file, an MP4 with English and German audio and subtitle tracks, and spoken English (MP4/AAC) and Japanese (MKV/Opus) clips that run the transcription pipeline through AVAssetReader and FFmpeg. The transcription tests need the en-US and ja-JP speech models installed. The track selection test plays the same multi-track file through both backends and expects the same results.

### HLS audio regression checks

`HLSPlaybackTests` includes a local master/variant playlist with muxed H.264/AAC
MPEG-TS content intentionally named `segment.mp4`. The fixture was remuxed from
`sample.mp4` (first second, stream copy). This checks audio extraction when a
segment filename differs from its actual format, as with CDN `.ts.jpg` URLs.
The FFmpeg audio decoder disables HLS `extension_picky`, matching mpv's existing
behavior; protocol and local-file extension allowlists are unchanged.

Optional live checks exercise mpv playback, direct FFmpeg decoding, and the
AVAssetReader-to-FFmpeg fallback without requiring speech models:

```sh
AVPLUS_LIVE_HLS_URL='https://cdn.example/master.m3u8' \
AVPLUS_LIVE_HLS_REFERER='https://embed.example/' \
AVPLUS_LIVE_HLS_USER_AGENT='Mozilla/5.0' \
swift test --filter HLSPlaybackTests
```

Without `AVPLUS_LIVE_HLS_URL`, only the offline test runs. Headless playback
checks audio-track discovery and advancing time, not audible sound or rendering.

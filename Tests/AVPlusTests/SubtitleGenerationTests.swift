import Foundation
import Speech
import Testing
@testable import AVPlus

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

/// End-to-end runs need the on-device speech model for the locale.
private func speechAvailable(_ identifier: String) async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
    return installed.contains(identifier)
}

@Suite(.serialized)
struct SubtitleGenerationTests {
    @Test func transcribesEnglishMP4WithAssetReader() async throws {
        try #require(await speechAvailable("en-US"), "en-US speech model not installed")
        let options = SubtitleGenerator.Options(locale: Locale(identifier: "en-US"), store: nil)
        let document = try await SubtitleGenerator().generate(for: try fixture("speech-en.mp4"), options: options)

        #expect(document.cues.count >= 3)
        let first = try #require(document.cues.first)
        // Two seconds of silence precede the speech; cue times are media-relative.
        #expect(first.start! > 1.5 && first.start! < 3)
        #expect(first.text.localizedCaseInsensitiveContains("welcome"))
        #expect(document.cues.contains { $0.text.localizedCaseInsensitiveContains("fox") })
        #expect(document.cues.last!.end! <= 12)
    }

    @Test func transcribesJapaneseMatroskaWithFFmpeg() async throws {
        try #require(await speechAvailable("ja-JP"), "ja-JP speech model not installed")
        let options = SubtitleGenerator.Options(locale: Locale(identifier: "ja-JP"), store: nil)
        let document = try await SubtitleGenerator().generate(for: try fixture("speech-ja.mkv"), options: options)

        #expect(document.cues.count >= 2)
        #expect(document.cues.first!.start! > 1.5)
        #expect(document.cues.contains { $0.text.contains("天気") })
        #expect(document.cues.allSatisfy { $0.text.count <= SubtitleSegmentation.japanese.maxCharacters })
    }
}

extension SubtitleGenerationTests {
    @Test func cachesTranscriptsAndReportsProgress() async throws {
        try #require(await speechAvailable("en-US"))
        let store = SubtitleStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? store.removeAll() }
        let options = SubtitleGenerator.Options(locale: Locale(identifier: "en-US"), store: store)
        let url = try fixture("speech-en.mp4")

        var progress: [Double] = []
        var streamedCues: [SubtitleCue] = []
        var finished: (SubtitleDocument, Bool)?
        for try await event in SubtitleGenerator().events(for: url, options: options) {
            switch event {
            case let .transcribing(value): progress.append(value)
            case let .cues(cues): streamedCues += cues
            case let .finished(document, fromCache): finished = (document, fromCache)
            case .downloadingModel: break
            }
        }
        let (document, fromCache) = try #require(finished)
        #expect(!fromCache)
        #expect(progress.first == 0 && progress.last == 1)
        #expect(progress == progress.sorted())
        #expect(streamedCues.map(\.text) == document.cues.map(\.text))

        // Second run is served from the store without transcribing.
        var events = 0
        for try await event in SubtitleGenerator().events(for: url, options: options) {
            events += 1
            if case let .finished(cached, fromCache) = event {
                #expect(fromCache)
                #expect(cached.cues.map(\.text) == document.cues.map(\.text))
            }
        }
        #expect(events == 1)
    }

    @Test func cancellationStopsGeneration() async throws {
        try #require(await speechAvailable("en-US"))
        let options = SubtitleGenerator.Options(locale: Locale(identifier: "en-US"), store: nil)
        let task = Task { try await SubtitleGenerator().generate(for: try fixture("speech-en.mp4"), options: options) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func reportsMissingAudio() async throws {
        try #require(SpeechTranscriber.isAvailable)
        // The SRT fixture is not media at all; both decoders refuse it.
        let options = SubtitleGenerator.Options(locale: Locale(identifier: "en-US"), store: nil)
        await #expect(throws: (any Error).self) {
            try await SubtitleGenerator().generate(for: try fixture("sample.srt"), options: options)
        }
    }

    @MainActor
    @Test(arguments: [BackendSelection.avFoundation, .mpv])
    func generatesSubtitlesForThePlayingVideo(backend: BackendSelection) async throws {
        try #require(await speechAvailable("en-US"))
        let store = SubtitleStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? store.removeAll() }
        let player = AVPlusPlayer(configuration: PlayerConfiguration(
            backend: backend,
            subtitleRendering: .native,
            mpvOptions: ["vo": "null", "ao": "null"]
        ))
        player.isMuted = true
        await player.load(try fixture("speech-en.mp4"), autoplay: false)
        #expect(await waitUntil { player.status == .paused })

        let generation = player.generateSubtitles(locale: Locale(identifier: "en-US"), store: nil)
        // The track exists right away and is selected; it fills in as transcription runs.
        let track = try #require(generation.track)
        #expect(track.isGenerated && track.isExternal)
        #expect(player.selectedSubtitleTrackID == track.id)
        #expect(player.subtitleTracks.contains { $0.id == track.id })
        // No backend draws these, so the overlay is needed even with native rendering.
        #expect(player.requiresSubtitleOverlay)

        let document = try await generation.value()
        #expect(generation.phase == .finished)
        #expect(document.cues.count >= 3)
        #expect(player.subtitleDocument(for: track)?.cues.count == document.cues.count)

        await player.seek(to: 6, precise: true)
        #expect(await waitUntil { player.subtitleCues.first?.text.localizedCaseInsensitiveContains("fox") == true })

        // Persist, then bring it back in a fresh player without transcribing again.
        try player.saveSubtitles(track, to: store)
        player.stop()

        let restoredPlayer = AVPlusPlayer(configuration: PlayerConfiguration(backend: backend, mpvOptions: ["vo": "null", "ao": "null"]))
        await restoredPlayer.load(try fixture("speech-en.mp4"), autoplay: false)
        let restored = restoredPlayer.restoreSubtitles(from: store, select: true)
        #expect(restored.count == 1)
        #expect(restored.first?.isGenerated == true)
        #expect(restoredPlayer.subtitleDocument(for: restored[0])?.cues.map(\.text) == document.cues.map(\.text))
        let again = restoredPlayer.generateSubtitles(locale: Locale(identifier: "en-US"), store: nil)
        #expect(again.isFromCache && again.track?.id == restored.first?.id)
        #expect(restoredPlayer.subtitleTracks.filter(\.isGenerated).count == 1)
        restoredPlayer.stop()
    }

    @MainActor
    @Test func cancellingRemovesTheEmptyTrack() async throws {
        try #require(await speechAvailable("en-US"))
        let player = AVPlusPlayer(configuration: PlayerConfiguration(mpvOptions: ["vo": "null", "ao": "null"]))
        await player.load(try fixture("speech-en.mp4"), autoplay: false)
        let generation = player.generateSubtitles(locale: Locale(identifier: "en-US"), store: nil)
        generation.cancel()
        await #expect(throws: CancellationError.self) { try await generation.value() }
        #expect(generation.phase == .cancelled)
        #expect(!player.subtitleTracks.contains { $0.isGenerated })
        #expect(player.selectedSubtitleTrackID == nil)
        player.stop()
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

struct SentenceGrouperTests {
    private func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.3) -> [TranscriptSegment] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * step
            return TranscriptSegment(text: (index == 0 ? "" : " ") + word, start: begin, end: begin + step)
        }
    }

    @Test func joinsSentencesThatSpanResults() {
        let grouper = SentenceGrouper(options: .english)
        // The recognizer ended a result mid-sentence.
        #expect(grouper.append(words("The quick brown fox", from: 0)).isEmpty)
        let cues = grouper.append(words("jumps over the dog. And then", from: 1.3))
        #expect(cues.map(\.text) == ["The quick brown fox jumps over the dog."])
        #expect(cues.first?.start == 0)
        // "dog." is the 4th word of the second result: 1.3 + 4 × 0.3.
        #expect(abs((cues.first?.end ?? 0) - 2.5) < 0.001)

        let tail = grouper.finish()
        #expect(tail.map(\.text) == ["And then"])
        #expect(abs((tail.first?.start ?? 0) - 2.5) < 0.001)
    }

    @Test func splitsSeveralSentencesInOneResult() {
        let grouper = SentenceGrouper(options: .english)
        let cues = grouper.append(words("Hello there. How are you? Fine.", from: 10))
        #expect(cues.map(\.text) == ["Hello there.", "How are you?", "Fine."])
        let starts = cues.compactMap(\.start)
        #expect(zip(starts, [10, 10.6, 11.5]).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func pauseEndsSentenceWithoutPunctuation() {
        let grouper = SentenceGrouper(options: .english)
        #expect(grouper.append(words("no punctuation here", from: 0)).isEmpty)
        let cues = grouper.append(words("after a long pause", from: 3))
        #expect(cues.map(\.text) == ["no punctuation here"])
        #expect(grouper.finish().map(\.text) == ["after a long pause"])
    }

    @Test func fallbackSplitsLongUnpunctuatedSpeech() {
        var options = SubtitleSegmentation.english
        options.maxCharacters = 40
        let grouper = SentenceGrouper(options: options)
        let text = "so we kept talking about the plan for the weekend and nobody ever stopped to breathe or end the sentence at all"
        var cues = grouper.append(words(text, from: 0))
        cues += grouper.finish()
        #expect(cues.count >= 3)
        #expect(cues.allSatisfy { $0.text.count <= 40 })
        #expect(cues.map(\.text).joined(separator: " ") == text)
        // Consecutive and non-overlapping.
        for (earlier, later) in zip(cues, cues.dropFirst()) { #expect(earlier.end! <= later.start! + 0.001) }
    }

    @Test func splitsLongCueAtThePause() {
        var options = SubtitleSegmentation.english
        options.maxDuration = 2
        let grouper = SentenceGrouper(options: options)
        var segments = words("one two three", from: 0)
        var second = words("four five six.", from: 1.9) // 1 s gap, under the pause threshold
        second[0].text = " " + second[0].text
        segments += second
        let cues = grouper.append(segments)
        #expect(cues.map(\.text) == ["one two three", "four five six."])
    }

    @Test func groupsJapaneseWithoutSpaces() {
        let grouper = SentenceGrouper(options: .japanese)
        let characters = Array("こんにちは。今日はいい天気ですね。")
        let segments = characters.enumerated().map { index, character in
            TranscriptSegment(text: String(character), start: Double(index) * 0.2, end: Double(index + 1) * 0.2)
        }
        let cues = grouper.append(Array(segments.prefix(9))) + grouper.append(Array(segments.dropFirst(9)))
        #expect(cues.map(\.text) == ["こんにちは。", "今日はいい天気ですね。"])
        #expect(abs(cues[1].start! - 1.2) < 0.001)
    }

    @Test func fallbackSplitsJapaneseWithoutPunctuation() {
        let grouper = SentenceGrouper(options: .japanese)
        // One long run without 。 that the recognizer delivered as a single segment.
        let text = String(repeating: "今日はとてもいい天気なので公園に散歩に行きます", count: 3)
        var cues = grouper.append([TranscriptSegment(text: text, start: 0, end: 12)])
        cues += grouper.finish()
        #expect(cues.count >= 3)
        #expect(cues.allSatisfy { $0.text.count <= SubtitleSegmentation.japanese.maxCharacters })
        #expect(cues.map(\.text).joined() == text)
        #expect(cues.first?.start == 0 && abs((cues.last?.end ?? 0) - 12) < 0.001)
    }

    @Test func polishExtendsShortCuesWithoutOverlap() {
        let cues = SentenceGrouper.polish([
            SubtitleCue(text: "A", start: 0, end: 0.2),
            SubtitleCue(text: "B", start: 0.5, end: 0.6),
            SubtitleCue(text: "C", start: 5, end: 5.1),
        ], minDuration: 1)
        #expect(cues.map(\.end) == [0.5, 1.5, 6])
    }
}

struct SubtitleExportTests {
    private let document = SubtitleDocument(cues: [
        SubtitleCue(text: "Hello & <welcome>", start: 1.5, end: 3.25),
        SubtitleCue(text: "Line one\n\nLine two", start: 3661.007, end: 3662),
    ])

    @Test func exportsSubRip() {
        let srt = document.export(as: .subRip)
        #expect(srt == """
        1
        00:00:01,500 --> 00:00:03,250
        Hello & <welcome>

        2
        01:01:01,007 --> 01:01:02,000
        Line one
        Line two

        """)
    }

    @Test func exportsWebVTTThatParsesBack() {
        let vtt = document.export(as: .webVTT)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello &amp; &lt;welcome&gt;\n"))
        let parsed = SubtitleDocument(contents: vtt)
        #expect(parsed.cues.map(\.text) == ["Hello & <welcome>", "Line one\nLine two"])
        #expect(parsed.cues.map(\.start) == [1.5, 3661.007])
    }

    @Test func writesByExtensionAndRoundTripsThroughJSON() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: file) }
        try document.write(to: file)
        #expect(SubtitleDocument(contents: try String(contentsOf: file, encoding: .utf8)).cues.count == 2)

        let decoded = try JSONDecoder().decode(SubtitleDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded.cues.map(\.text) == document.cues.map(\.text))
        #expect(decoded.cues.map(\.end) == document.cues.map(\.end))
    }

    @Test func storeKeysByMediaIdentity() throws {
        let store = SubtitleStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? store.removeAll() }
        let media = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("one".utf8).write(to: media)
        defer { try? FileManager.default.removeItem(at: media) }

        try store.save(SubtitleStore.Entry(variant: "a", title: "A", document: document), for: media)
        try store.save(SubtitleStore.Entry(variant: "b", language: "ja", isGenerated: true, document: document), for: media)
        #expect(store.entries(for: media).map(\.variant) == ["a", "b"])
        #expect(store.entry(for: media, variant: "b")?.isGenerated == true)

        // Changing the file invalidates its entries.
        try Data("changed contents".utf8).write(to: media)
        #expect(store.entries(for: media).isEmpty)
    }
}

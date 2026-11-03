import Foundation
import Testing
@testable import AVPlus

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
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

/// mpv renders nowhere in tests; null outputs keep it headless.
private let headlessMPV = ["vo": "null", "ao": "null"]

struct BackendResolverTests {
    @Test func decidesFromURLWhenPossible() {
        #expect(BackendResolver.quickDecision(for: URL(string: "https://example.com/a.mkv")!) == .mpv)
        #expect(BackendResolver.quickDecision(for: URL(string: "https://example.com/a.WEBM")!) == .mpv)
        #expect(BackendResolver.quickDecision(for: URL(string: "rtsp://camera.local/stream")!) == .mpv)
        #expect(BackendResolver.quickDecision(for: URL(string: "https://example.com/master.m3u8")!) == .avFoundation)
        #expect(BackendResolver.quickDecision(for: URL(string: "https://example.com/movie.mp4")!) == nil)
    }

    @Test func probesAmbiguousFiles() async throws {
        #expect(await BackendResolver.resolve(try fixture("sample.mp4"), selection: .automatic, probeTimeout: .seconds(5)) == .avFoundation)

        // A Matroska file without a telling extension has to be detected by probing.
        let disguised = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        try FileManager.default.copyItem(at: try fixture("sample.mkv"), to: disguised)
        defer { try? FileManager.default.removeItem(at: disguised) }
        #expect(await BackendResolver.resolve(disguised, selection: .automatic, probeTimeout: .seconds(5)) == .mpv)
    }

    @Test func honorsForcedSelection() async throws {
        #expect(await BackendResolver.resolve(try fixture("sample.mp4"), selection: .mpv, probeTimeout: .seconds(1)) == .mpv)
    }
}

@MainActor
@Suite(.serialized)
struct PlaybackTests {
    @Test func playsMP4WithAVFoundationAndSidecarSubtitles() async throws {
        let player = AVPlusPlayer(configuration: PlayerConfiguration(mpvOptions: headlessMPV))
        player.isMuted = true
        await player.load(try fixture("sample.mp4"))
        try await player.addSubtitle(url: try fixture("sample.srt"), language: "en")

        #expect(player.backend == .avFoundation)
        #expect(await waitUntil { player.status == .playing })
        #expect(await waitUntil { player.subtitleCues.first?.text == "Hello world" })
        #expect(player.subtitleTracks.contains { $0.isExternal && $0.language == "en" })
        #expect(player.selectedSubtitleTrack?.isExternal == true)
        #expect(player.duration.map { abs($0 - 3) < 0.2 } == true)
        #expect(player.videoSize == CGSize(width: 320, height: 240))

        player.pause()
        #expect(await waitUntil { player.status == .paused })
        await player.seek(to: 2, precise: true)
        #expect(await waitUntil { player.subtitleCues.first?.text == "Second line" })

        player.selectSubtitleTrack(nil)
        #expect(player.subtitleCues.isEmpty)
        player.stop()
        #expect(player.status == .idle)
    }

    @Test func playsMatroskaWithMPVAndEmbeddedSubtitles() async throws {
        let player = AVPlusPlayer(configuration: PlayerConfiguration(mpvOptions: headlessMPV))
        await player.load(try fixture("sample.mkv"))

        #expect(player.backend == .mpv)
        #expect(await waitUntil { player.status == .playing })
        #expect(await waitUntil { !player.subtitleTracks.isEmpty })
        let english = try #require(player.subtitleTracks.first { $0.language == "eng" })
        player.selectSubtitleTrack(english)

        #expect(await waitUntil { player.subtitleCues.first?.text == "Hello world" })
        #expect(player.subtitleCues.first?.start != nil)
        #expect(player.audioTracks.count == 1)
        #expect(await waitUntil { player.videoSize == CGSize(width: 320, height: 240) })

        player.pause()
        #expect(await waitUntil { player.status == .paused })
        await player.seek(to: 2, precise: true)
        #expect(await waitUntil { player.subtitleCues.first?.text == "Second line" })

        player.rate = 2
        #expect(await waitUntil { player.rate == 2 })
        player.play()
        #expect(await waitUntil { player.status == .ended })
        player.stop()
    }

    /// SRT and WebVTT added while the video is already playing, from text and from a file.
    @Test(arguments: [PlaybackBackend.avFoundation, .mpv])
    func addsAndRemovesSubtitlesDuringPlayback(backend: PlaybackBackend) async throws {
        let selection: BackendSelection = backend == .mpv ? .mpv : .avFoundation
        let player = AVPlusPlayer(configuration: PlayerConfiguration(backend: selection, mpvOptions: headlessMPV))
        player.isMuted = true
        await player.load(try fixture("sample.mp4"))
        #expect(await waitUntil { player.status == .playing })
        #expect(player.backend == backend)
        player.pause()
        #expect(await waitUntil { player.status == .paused })

        let webVTT = """
        WEBVTT

        00:00.000 --> 00:03.000
        <i>Added</i> while playing
        """
        let vttTrack = try #require(try await player.addSubtitle(text: webVTT, language: "de"))
        #expect(vttTrack.isExternal)
        #expect(await waitUntil { player.subtitleCues.first?.text == "Added while playing" })
        #expect(await waitUntil { player.subtitleTracks.contains { $0.id == vttTrack.id } })
        #expect(player.selectedSubtitleTrackID == vttTrack.id)

        let srtTrack = try #require(try await player.addSubtitle(url: try fixture("sample.srt"), title: "English", language: "en"))
        #expect(srtTrack.id != vttTrack.id)
        await player.seek(to: 2, precise: true)
        #expect(await waitUntil { player.subtitleCues.first?.text == "Second line" })
        #expect(await waitUntil { player.subtitleTracks.filter(\.isExternal).count == 2 })

        // Switching back to the first added track.
        player.selectSubtitleTrack(vttTrack)
        #expect(await waitUntil { player.subtitleCues.first?.text == "Added while playing" })

        player.removeSubtitle(vttTrack)
        #expect(player.selectedSubtitleTrackID == nil)
        #expect(player.subtitleCues.isEmpty)
        #expect(await waitUntil { player.subtitleTracks.filter(\.isExternal).map(\.id) == [srtTrack.id] })
        player.stop()
    }

    @Test func rejectsUnrecognizedSubtitleText() async throws {
        let player = AVPlusPlayer(configuration: PlayerConfiguration(mpvOptions: headlessMPV))
        await #expect(throws: (any Error).self) { try await player.addSubtitle(text: "WEBVTT\n") }
        await player.load(try fixture("sample.mp4"), autoplay: false)
        await #expect(throws: SubtitleDocument.ParseError.self) { try await player.addSubtitle(text: "just words") }
        player.stop()
    }

    @Test func mpvReportsMissingFiles() async throws {
        let player = AVPlusPlayer(configuration: PlayerConfiguration(backend: .mpv, mpvOptions: headlessMPV))
        await player.load(URL(filePath: "/nonexistent/\(UUID().uuidString).mkv"))
        #expect(await waitUntil {
            if case .failed = player.status { return true }
            return false
        })
        player.stop()
    }

    @Test func avFoundationFailureFallsBackToMPV() async throws {
        // Skip the probe by pretending the URL is HLS. AVPlayer stalls on it without ever failing,
        // so the ready timeout has to trigger the fallback.
        let disguised = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m3u8")
        try FileManager.default.copyItem(at: try fixture("sample.mkv"), to: disguised)
        defer { try? FileManager.default.removeItem(at: disguised) }

        let player = AVPlusPlayer(configuration: PlayerConfiguration(probeTimeout: .seconds(1), mpvOptions: headlessMPV))
        await player.load(disguised)
        #expect(player.backend == .avFoundation)
        #expect(await waitUntil { player.backend == .mpv })
        #expect(await waitUntil { player.status == .playing })
        player.stop()
    }
}

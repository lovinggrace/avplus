import Foundation
import Testing
@testable import AVPlus

@MainActor
struct HLSPlaybackTests {
    // MPEG-TS content intentionally named .mp4: the extension is allowed for
    // local HLS, but disagrees with the detected demuxer just like .ts.jpg.
    @Test func decodesMuxedAudioWithMismatchedSegmentExtension() throws {
        let url = try #require(Bundle.module.url(
            forResource: "master", withExtension: "m3u8", subdirectory: "Fixtures/hls-muxed"
        ))
        let decoder = try FFmpegAudioDecoder(url: url, trackIndex: nil, sampleRate: 16000)
        let chunk = try #require(try decoder.nextChunk())
        #expect(!chunk.samples.isEmpty)
        #expect(chunk.sampleRate == 16000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVPLUS_LIVE_HLS_URL"] != nil))
    func playsLiveHLSWithMuxedAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["AVPLUS_LIVE_HLS_URL"].flatMap(URL.init(string:)))
        let player = AVPlusPlayer(configuration: PlayerConfiguration(
            backend: .mpv, mpvOptions: ["vo": "null", "ao": "null"]
        ))
        defer { player.stop() }
        await player.load(url, headers: [
            "Referer": environment["AVPLUS_LIVE_HLS_REFERER"] ?? "",
            "User-Agent": environment["AVPLUS_LIVE_HLS_USER_AGENT"] ?? "Mozilla/5.0",
        ])
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if player.status == .playing, !player.audioTracks.isEmpty, player.currentTime > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.status == .playing)
        #expect(!player.audioTracks.isEmpty)
        #expect(player.selectedAudioTrackID != nil)
        #expect(player.currentTime > 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVPLUS_LIVE_HLS_URL"] != nil))
    func decodesLiveHLSAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["AVPLUS_LIVE_HLS_URL"].flatMap(URL.init(string:)))
        let decoder = try await AudioDecoding.makeDecoder(url: url, headers: HTTPHeaders([
            "Referer": environment["AVPLUS_LIVE_HLS_REFERER"] ?? "",
            "User-Agent": environment["AVPLUS_LIVE_HLS_USER_AGENT"] ?? "Mozilla/5.0",
        ]), trackIndex: nil, sampleRate: 16000)
        let chunk = try #require(try decoder.nextChunk())
        #expect(!chunk.samples.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVPLUS_LIVE_HLS_URL"] != nil))
    func decodesLiveHLSAudioWithFFmpeg() throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["AVPLUS_LIVE_HLS_URL"].flatMap(URL.init(string:)))
        let decoder = try FFmpegAudioDecoder(url: url, headers: HTTPHeaders([
            "Referer": environment["AVPLUS_LIVE_HLS_REFERER"] ?? "",
            "User-Agent": environment["AVPLUS_LIVE_HLS_USER_AGENT"] ?? "Mozilla/5.0",
        ]), trackIndex: nil, sampleRate: 16000)
        let chunk = try #require(try decoder.nextChunk())
        #expect(!chunk.samples.isEmpty)
    }

}

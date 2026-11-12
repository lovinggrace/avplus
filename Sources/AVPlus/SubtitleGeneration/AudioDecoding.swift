import AVFoundation
import Foundation

/// A run of mono Float32 samples starting at a media-relative time.
struct DecodedAudioChunk: Sendable {
    var samples: [Float]
    /// Seconds on the media timeline, i.e. the same clock `AVPlayer.currentTime()` and mpv's
    /// `time-pos` use.
    var startTime: TimeInterval
    var sampleRate: Double

    var duration: TimeInterval { Double(samples.count) / sampleRate }
}

/// Pull-based decoding of one audio track. Pulling (instead of pushing into a buffer) gives the
/// speech analyzer natural backpressure, so long media never sits decoded in memory.
///
/// Implementations are used from one task at a time.
protocol AudioChunkDecoder: AnyObject, Sendable {
    /// Media duration in seconds, if known.
    var duration: TimeInterval? { get }
    /// Returns `nil` at the end of the track.
    func nextChunk() throws -> DecodedAudioChunk?
}

public enum SubtitleGenerationError: Error, Sendable, LocalizedError, Equatable {
    case speechRecognitionUnavailable
    case unsupportedLocale(String)
    case modelNotInstalled(String)
    case noAudioTrack
    case decodingFailed(String)
    case noMedia

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionUnavailable: "On-device speech recognition is not available on this device."
        case let .unsupportedLocale(locale): "Speech recognition does not support \(locale)."
        case let .modelNotInstalled(locale): "The speech model for \(locale) is not installed."
        case .noAudioTrack: "The media has no audio track to transcribe."
        case let .decodingFailed(reason): "The audio could not be decoded: \(reason)"
        case .noMedia: "No media is loaded."
        }
    }
}

enum AudioDecoding {
    /// Opens the `trackIndex`-th audio track (in file order) with AVAssetReader, falling back to
    /// FFmpeg for containers and codecs AVFoundation cannot read.
    /// - Parameter prefersCenterChannel: For surround tracks, decode only the front centre channel.
    ///   Those tracks always go through FFmpeg, which can pick a channel.
    static func makeDecoder(
        url: URL,
        headers: HTTPHeaders = HTTPHeaders([:]),
        trackIndex: Int?,
        sampleRate: Double,
        prefersCenterChannel: Bool = false
    ) async throws -> any AudioChunkDecoder {
        var assetReaderError: (any Error)?
        if BackendResolver.quickDecision(for: url) != .mpv {
            do {
                return try await AssetReaderAudioDecoder.make(
                    url: url, headers: headers, trackIndex: trackIndex, sampleRate: sampleRate, rejectsSurround: prefersCenterChannel
                )
            } catch {
                // Not a failure to report if FFmpeg then succeeds or fails for its own reason.
                if !(error is AssetReaderAudioDecoder.SurroundTrack) { assetReaderError = error }
            }
        }
        do {
            return try FFmpegAudioDecoder(
                url: url, headers: headers, trackIndex: trackIndex, sampleRate: sampleRate, prefersCenterChannel: prefersCenterChannel
            )
        } catch {
            // Prefer AVFoundation's explanation when both failed, e.g. "no audio track".
            throw assetReaderError ?? error
        }
    }
}

// MARK: - AVAssetReader

final class AssetReaderAudioDecoder: AudioChunkDecoder, @unchecked Sendable {
    let duration: TimeInterval?
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let sampleRate: Double
    /// The first chunk, read eagerly in `make` so unsupported codecs fail there (and fall back).
    private var firstChunk: DecodedAudioChunk?

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, duration: TimeInterval?, sampleRate: Double) {
        self.reader = reader
        self.output = output
        self.duration = duration
        self.sampleRate = sampleRate
    }

    /// Thrown by `make` for a track with more than two channels when the caller wants to pick one.
    struct SurroundTrack: Error {}

    static func make(
        url: URL,
        headers: HTTPHeaders = HTTPHeaders([:]),
        trackIndex: Int?,
        sampleRate: Double,
        rejectsSurround: Bool = false
    ) async throws -> AssetReaderAudioDecoder {
        let asset = AVURLAsset(url: url, options: headers.assetOptions)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let index = trackIndex ?? 0
        guard tracks.indices.contains(index) else { throw SubtitleGenerationError.noAudioTrack }
        if rejectsSurround {
            let channels = try await tracks[index].load(.formatDescriptions)
                .compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }.max() ?? 0
            if channels > 2 { throw SurroundTrack() }
        }
        let duration = try await asset.load(.duration)

        let reader = try AVAssetReader(asset: asset)
        // AVAssetReader resamples and downmixes to what the speech analyzer wants.
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SubtitleGenerationError.decodingFailed("AVAssetReader cannot read this audio track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SubtitleGenerationError.decodingFailed(reader.error?.localizedDescription ?? "AVAssetReader failed")
        }

        let decoder = AssetReaderAudioDecoder(
            reader: reader,
            output: output,
            duration: duration.isNumeric ? duration.seconds : nil,
            sampleRate: sampleRate
        )
        decoder.firstChunk = try decoder.readChunk()
        return decoder
    }

    func nextChunk() throws -> DecodedAudioChunk? {
        if let firstChunk {
            self.firstChunk = nil
            return firstChunk
        }
        return try readChunk()
    }

    private func readChunk() throws -> DecodedAudioChunk? {
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var samples = [Float](repeating: 0, count: frameCount)
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            var start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            // Encoder priming can start slightly before zero; the player timeline cannot.
            if start < 0 {
                let drop = min(samples.count, Int((-start * sampleRate).rounded()))
                samples.removeFirst(drop)
                start = 0
                if samples.isEmpty { continue }
            }
            return DecodedAudioChunk(samples: samples, startTime: start, sampleRate: sampleRate)
        }
        if reader.status == .failed {
            throw SubtitleGenerationError.decodingFailed(reader.error?.localizedDescription ?? "AVAssetReader failed")
        }
        return nil
    }

    deinit {
        reader.cancelReading()
    }
}

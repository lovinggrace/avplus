import AVFoundation
import Foundation
import Speech

/// Generates subtitles for a media file on device, independently of any player.
///
/// The pipeline:
/// 1. **Decode:** the chosen audio track is decoded to PCM with AVAssetReader, or with FFmpeg for
///    formats AVFoundation cannot read (Matroska, WebM, Opus, ...). Every buffer carries its time
///    on the media timeline.
/// 2. **Transcribe:** buffers are fed to `SpeechAnalyzer` with a `SpeechTranscriber` that reports
///    `audioTimeRange` attributes. Since buffer start times are media times, word timings are too.
/// 3. **Group:** words are joined into sentences with `NLTokenizer`, including sentences that span
///    several recognition results. Long pauses and length limits split text that has no
///    punctuation.
///
/// ```swift
/// let generator = SubtitleGenerator()
/// for try await event in generator.events(for: movieURL, options: .init(locale: Locale(identifier: "ja-JP"))) {
///     if case let .finished(document, _) = event {
///         try document.write(to: movieURL.deletingPathExtension().appendingPathExtension("srt"))
///     }
/// }
/// ```
public struct SubtitleGenerator: Sendable {
    public struct Options: Sendable {
        /// The spoken language. Matched to the closest locale the transcriber supports.
        public var locale: Locale
        /// The audio track to transcribe, as an index among the media's audio tracks in file
        /// order. `nil` uses the first one.
        public var audioTrackIndex: Int?
        /// How the transcript is cut into cues. `nil` uses ``SubtitleSegmentation/defaults(for:)``.
        public var segmentation: SubtitleSegmentation?
        /// Download the speech model if it is not installed yet.
        public var allowsModelDownload: Bool
        /// Where results are looked up and saved. `nil` disables caching.
        public var store: SubtitleStore?

        public init(
            locale: Locale = .current,
            audioTrackIndex: Int? = nil,
            segmentation: SubtitleSegmentation? = nil,
            allowsModelDownload: Bool = true,
            store: SubtitleStore? = .cache
        ) {
            self.locale = locale
            self.audioTrackIndex = audioTrackIndex
            self.segmentation = segmentation
            self.allowsModelDownload = allowsModelDownload
            self.store = store
        }
    }

    public enum Event: Sendable {
        /// The speech model is downloading; `progress` is `0...1`.
        case downloadingModel(progress: Double)
        /// Transcription progress, `0...1` of the media duration.
        case transcribing(progress: Double)
        /// Cues that became final, in order. Earlier cues never change.
        case cues([SubtitleCue])
        /// The complete, polished document. `fromCache` is `true` when nothing was transcribed.
        case finished(SubtitleDocument, fromCache: Bool)
    }

    public init() {}

    /// Whether on-device transcription can handle `locale` on this device.
    public static func supports(_ locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// Runs the pipeline and reports progress and cues as they become final. Cancelling the
    /// consuming task (or dropping the stream) stops decoding and transcription.
    public func events(for url: URL, options: Options = Options()) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(url: url, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Generates the whole document. Throws `CancellationError` when the task is cancelled.
    public func generate(
        for url: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SubtitleDocument {
        for try await event in events(for: url, options: options) {
            switch event {
            case let .transcribing(value): progress?(value)
            case let .finished(document, _): return document
            case .downloadingModel, .cues: break
            }
        }
        try Task.checkCancellation()
        throw CancellationError()
    }

    // MARK: - Pipeline

    private static func run(url: URL, options: Options, emit: @escaping @Sendable (Event) -> Void) async throws {
        let variant = SubtitleStore.generatedVariant(locale: options.locale, audioTrackIndex: options.audioTrackIndex)
        if let entry = options.store?.entry(for: url, variant: variant) {
            emit(.finished(entry.document, fromCache: true))
            return
        }

        guard SpeechTranscriber.isAvailable else { throw SubtitleGenerationError.speechRecognitionUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.locale) else {
            throw SubtitleGenerationError.unsupportedLocale(options.locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await installModelIfNeeded(for: transcriber, locale: locale, options: options, emit: emit)
        try Task.checkCancellation()

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let decoder = try await AudioDecoding.makeDecoder(
            url: url,
            trackIndex: options.audioTrackIndex,
            sampleRate: analyzerFormat.sampleRate
        )
        let duration = decoder.duration
        let activity = SpeechActivityMap(sampleRate: analyzerFormat.sampleRate)
        let source = AnalyzerInputSource(decoder: decoder, format: analyzerFormat, activity: activity) { time in
            guard let duration, duration > 0 else { return }
            emit(.transcribing(progress: min(1, time / duration)))
        }
        emit(.transcribing(progress: 0))

        let segmentation = options.segmentation ?? .defaults(for: locale)
        let results = Task {
            let grouper = SentenceGrouper(options: segmentation)
            var cues: [SubtitleCue] = []
            for try await result in transcriber.results where result.isFinal {
                let new = grouper.append(activity.refine(segments(of: result.text)))
                if !new.isEmpty {
                    cues += new
                    emit(.cues(new))
                }
            }
            let tail = grouper.finish()
            if !tail.isEmpty {
                cues += tail
                emit(.cues(tail))
            }
            return cues
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(AnalyzerInputSequence(source: source)) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            if let error = source.error { throw error }
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let cues = try await results.value
        try Task.checkCancellation()
        let document = SubtitleDocument(cues: SentenceGrouper.polish(cues, minDuration: segmentation.minDuration))
        try? options.store?.save(
            SubtitleStore.Entry(variant: variant, language: locale.identifier(.bcp47), isGenerated: true, document: document),
            for: url
        )
        emit(.transcribing(progress: 1))
        emit(.finished(document, fromCache: false))
    }

    private static func installModelIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        options: Options,
        emit: @escaping @Sendable (Event) -> Void
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        guard options.allowsModelDownload else {
            throw SubtitleGenerationError.modelNotInstalled(locale.identifier)
        }
        let progress = request.progress
        let reporter = Task {
            while !Task.isCancelled {
                emit(.downloadingModel(progress: progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        emit(.downloadingModel(progress: 1))
    }

    /// Splits a transcriber result into runs that share one audio time range.
    static func segments(of text: AttributedString) -> [TranscriptSegment] {
        text.runs.map { run in
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            return TranscriptSegment(
                text: String(text[run.range].characters),
                start: range.map(\.start.seconds),
                end: range.map(\.end.seconds)
            )
        }
    }
}

// MARK: - Analyzer input

/// Pulls decoded audio on demand, merges it into buffers of a useful size and converts them to
/// the analyzer's format. Used by one consumer (the analyzer) at a time.
final class AnalyzerInputSource: @unchecked Sendable {
    private let decoder: any AudioChunkDecoder
    private let format: AVAudioFormat
    private let onProgress: @Sendable (TimeInterval) -> Void
    private let activity: SpeechActivityMap?
    private var carry: DecodedAudioChunk?
    /// End of the audio handed to the analyzer so far, in samples.
    private var nextSamplePosition: Int64 = 0
    private(set) var error: (any Error)?

    /// About a quarter second; FFmpeg codecs like Opus decode 20 ms frames.
    private var minimumFrames: Int { Int(format.sampleRate / 4) }

    init(
        decoder: any AudioChunkDecoder,
        format: AVAudioFormat,
        activity: SpeechActivityMap? = nil,
        onProgress: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.decoder = decoder
        self.format = format
        self.activity = activity
        self.onProgress = onProgress
    }

    func next() -> AnalyzerInput? {
        guard !Task.isCancelled, error == nil else { return nil }
        let rate = format.sampleRate
        var samples: [Float] = []
        var startSample: Int64?

        while samples.count < minimumFrames {
            guard var chunk = nextDecodedChunk() else { break }
            var chunkStart = Int64((chunk.startTime * rate).rounded())
            // The analyzer rejects input that overlaps earlier input. Decoders can overlap by a
            // few samples (codec delay, rounding), so trim to strictly increasing sample positions.
            let earliest = startSample.map { $0 + Int64(samples.count) } ?? nextSamplePosition
            if chunkStart < earliest {
                let overlap = Int(earliest - chunkStart)
                guard overlap < chunk.samples.count else { continue }
                chunk.samples.removeFirst(overlap)
                chunkStart = earliest
            }
            // A real gap (> 20 ms) starts a new buffer, so timestamps stay exact.
            if let startSample, chunkStart - (startSample + Int64(samples.count)) > Int64(rate / 50) {
                carry = chunk
                break
            }
            if startSample == nil { startSample = chunkStart }
            samples += chunk.samples
        }

        guard let startSample, !samples.isEmpty, let buffer = makeBuffer(samples) else { return nil }
        nextSamplePosition = startSample + Int64(samples.count)
        activity?.append(samples, startSample: startSample)
        onProgress(Double(nextSamplePosition) / rate)
        return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: startSample, timescale: CMTimeScale(rate)))
    }

    private func nextDecodedChunk() -> DecodedAudioChunk? {
        if let carry {
            self.carry = nil
            return carry
        }
        do {
            return try decoder.nextChunk()
        } catch {
            self.error = error
            return nil
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = Int(format.channelCount)
        // Interleaved formats expose a single buffer holding all channels.
        let stride = format.isInterleaved ? channels : 1
        let buffers = format.isInterleaved ? 1 : channels

        switch format.commonFormat {
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            for channelBuffer in 0..<buffers {
                for (frame, sample) in samples.enumerated() {
                    let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
                    for channel in 0..<stride { data[channelBuffer][frame * stride + channel] = value }
                }
            }
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            for channelBuffer in 0..<buffers {
                for (frame, sample) in samples.enumerated() {
                    for channel in 0..<stride { data[channelBuffer][frame * stride + channel] = sample }
                }
            }
        default:
            return nil
        }
        return buffer
    }
}

/// Exposes ``AnalyzerInputSource`` as the async sequence `SpeechAnalyzer` consumes.
struct AnalyzerInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let source: AnalyzerInputSource

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: AnalyzerInputSource

        func next() async -> AnalyzerInput? {
            source.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source)
    }
}

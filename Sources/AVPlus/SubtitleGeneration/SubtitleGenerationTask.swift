import Foundation
import Observation

/// A running (or finished) subtitle generation, observable from SwiftUI.
///
/// ```swift
/// let generation = player.generateSubtitles(locale: Locale(identifier: "ja-JP"))
/// ProgressView(value: generation.progress)
/// Button("Cancel") { generation.cancel() }
/// ```
@MainActor
@Observable
public final class SubtitleGenerationTask: Identifiable {
    public enum Phase: Sendable, Equatable {
        case waiting
        /// The speech model is downloading; see ``modelDownloadProgress``.
        case downloadingModel
        case transcribing
        case finished
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let locale: Locale
    public private(set) var phase: Phase = .waiting
    /// Transcription progress, `0...1` of the media duration.
    public private(set) var progress: Double = 0
    /// Model download progress while ``phase`` is ``Phase/downloadingModel``.
    public private(set) var modelDownloadProgress: Double?
    /// Cues transcribed so far, final ones only.
    public private(set) var cues: [SubtitleCue] = []
    /// The finished document.
    public private(set) var document: SubtitleDocument?
    public private(set) var error: (any Error)?
    /// `true` when the result came from a ``SubtitleStore`` instead of a new transcription.
    public private(set) var isFromCache = false
    /// The player track showing these subtitles, when started from a player.
    public internal(set) var track: MediaTrack?

    @ObservationIgnored private var task: Task<Void, Never>?

    public var isRunning: Bool {
        switch phase {
        case .waiting, .downloadingModel, .transcribing: true
        case .finished, .failed, .cancelled: false
        }
    }

    init(locale: Locale) {
        self.locale = locale
    }

    /// Stops decoding and transcription. Cues produced so far stay in ``cues``.
    public func cancel() {
        task?.cancel()
    }

    /// Waits for the generation to end and returns its document.
    /// - Throws: `CancellationError` if cancelled, or the generation's error.
    public func value() async throws -> SubtitleDocument {
        await task?.value
        switch phase {
        case .finished: return document ?? SubtitleDocument(cues: cues)
        case .cancelled: throw CancellationError()
        default: throw error ?? CancellationError()
        }
    }

    func start(
        _ events: AsyncThrowingStream<SubtitleGenerator.Event, any Error>,
        onUpdate: @escaping @MainActor (SubtitleDocument) -> Void,
        onEnd: @escaping @MainActor (SubtitleGenerationTask) -> Void
    ) {
        task = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    self.apply(event, onUpdate: onUpdate)
                }
                if let self, self.phase != .finished { self.phase = .cancelled }
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.error = error
                self?.phase = .failed(error.localizedDescription)
            }
            if let self { onEnd(self) }
        }
    }

    func finish(with document: SubtitleDocument, fromCache: Bool) {
        self.document = document
        cues = document.cues
        isFromCache = fromCache
        progress = 1
        phase = .finished
    }

    func fail(_ error: any Error) {
        self.error = error
        phase = .failed(error.localizedDescription)
    }

    private func apply(_ event: SubtitleGenerator.Event, onUpdate: @MainActor (SubtitleDocument) -> Void) {
        switch event {
        case let .downloadingModel(value):
            phase = .downloadingModel
            modelDownloadProgress = value
        case let .transcribing(value):
            phase = .transcribing
            progress = value
        case let .cues(new):
            cues += new
            onUpdate(SubtitleDocument(cues: cues))
        case let .finished(document, fromCache):
            finish(with: document, fromCache: fromCache)
            onUpdate(document)
        }
    }
}

extension AVPlusPlayer {
    /// Transcribes the current media on device and adds the result as a subtitle track.
    ///
    /// The track appears right away and fills in as sentences are recognized, so viewers can turn
    /// it on while transcription is still running. It works the same with both backends, and the
    /// generation reads the media file independently of playback.
    ///
    /// - Parameters:
    ///   - locale: The spoken language, e.g. `Locale(identifier: "en-US")` or `"ja-JP"`.
    ///   - audioTrack: The audio track to transcribe. Defaults to the selected one.
    ///   - store: Where finished transcripts are looked up and saved. Pass ``SubtitleStore/persistent``
    ///     to keep them beyond cache purges, or `nil` to always transcribe.
    ///   - select: Shows the generated track immediately.
    @discardableResult
    public func generateSubtitles(
        locale: Locale = .current,
        audioTrack: MediaTrack? = nil,
        segmentation: SubtitleSegmentation? = nil,
        store: SubtitleStore? = .cache,
        select: Bool = true
    ) -> SubtitleGenerationTask {
        let generation = SubtitleGenerationTask(locale: locale)
        guard let url else {
            generation.fail(SubtitleGenerationError.noMedia)
            return generation
        }

        let audio = audioTrack ?? selectedAudioTrack
        let audioIndex = audio.flatMap { audio in audioTracks.firstIndex { $0.id == audio.id } }
        let variant = SubtitleStore.generatedVariant(locale: locale, audioTrackIndex: audioIndex)

        // Already showing (e.g. restored from a store): reuse it instead of adding a duplicate.
        if let existing = documentTrack(withVariant: variant) {
            generation.track = existing.track
            generation.finish(with: existing.document, fromCache: true)
            if select { selectSubtitleTrack(existing.track) }
            return generation
        }

        guard let track = try? addSubtitle(
            document: SubtitleDocument(cues: []),
            title: "Auto-generated",
            language: locale.language.minimalIdentifier,
            isGenerated: true,
            select: select
        ) else {
            generation.fail(SubtitleGenerationError.noMedia)
            return generation
        }
        setStoreVariant(variant, for: track.id)
        generation.track = track

        let options = SubtitleGenerator.Options(
            locale: locale,
            audioTrackIndex: audioIndex,
            segmentation: segmentation,
            store: store
        )
        subtitleGenerations.append(generation)
        generation.start(SubtitleGenerator().events(for: url, options: options)) { [weak self] document in
            self?.updateDocument(document, for: track.id)
        } onEnd: { [weak self] generation in
            guard let self else { return }
            self.subtitleGenerations.removeAll { $0 === generation }
            // Nothing recognized (failed, cancelled early, or no speech): no empty track.
            if generation.cues.isEmpty {
                self.removeSubtitle(track)
            }
        }
        return generation
    }
}

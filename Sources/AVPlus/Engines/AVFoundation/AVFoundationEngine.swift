import AVFoundation
import Combine
import Foundation

/// Plays media through `AVPlayer` and surfaces subtitles through `AVPlayerItemLegibleOutput`.
@MainActor
final class AVFoundationEngine: PlaybackEngine {
    let backend = PlaybackBackend.avFoundation
    var eventHandler: ((EngineEvent) -> Void)?

    let player = AVPlayer()

    private let configuration: PlayerConfiguration
    private let readyTimeout: Duration?
    private var readyTimeoutTask: Task<Void, Never>?
    private let legibleReceiver = LegibleOutputReceiver()
    private var playerCancellables: Set<AnyCancellable> = []
    private var itemCancellables: Set<AnyCancellable> = []
    private var timeObserver: Any?

    private var item: AVPlayerItem?
    private var pendingStartTime: TimeInterval?
    private var autoplay = true
    private var isReady = false
    private var hasEnded = false

    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var audioOptions: [String: AVMediaSelectionOption] = [:]
    private var legibleOptions: [String: AVMediaSelectionOption] = [:]
    private var audioTracks: [MediaTrack] = []
    private var embeddedSubtitleTracks: [MediaTrack] = []

    private var sidecars: [(track: MediaTrack, document: SubtitleDocument)] = []
    private var activeSidecarID: String?
    private var nextSidecarNumber = 0
    private var visibleSidecarCueIDs: [UUID] = []

    /// - Parameter readyTimeout: Report a failure if the item is not ready by then. AVPlayer can
    ///   stall indefinitely on media it cannot handle, so this lets the player fall back to mpv.
    init(configuration: PlayerConfiguration, readyTimeout: Duration? = nil) {
        self.configuration = configuration
        self.readyTimeout = readyTimeout
        #if !os(visionOS)
        player.allowsExternalPlayback = true
        #endif
        observePlayer()
        legibleReceiver.onCues = { [weak self] cues in
            self?.didReceiveLegible(cues)
        }
    }

    // MARK: - PlaybackEngine

    func load(url: URL, startTime: TimeInterval?, autoplay: Bool) {
        resetItemState()
        self.autoplay = autoplay
        pendingStartTime = startTime

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = configuration.subtitleRendering == .client
        output.setDelegate(legibleReceiver, queue: .main)
        item.add(output)

        self.item = item
        observe(item)
        emit(.status(.loading))
        player.replaceCurrentItem(with: item)

        if let readyTimeout {
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: readyTimeout)
                guard !Task.isCancelled, let self, self.item === item, !self.isReady else { return }
                self.player.replaceCurrentItem(with: nil)
                let error = PlaybackError("AVFoundation did not become ready in time", backend: .avFoundation)
                self.emit(.failed(error, beforeReady: true))
            }
        }
    }

    func play() {
        if hasEnded {
            hasEnded = false
            player.seek(to: .zero)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval, precise: Bool) async -> Bool {
        let tolerance: CMTime = precise ? .zero : .positiveInfinity
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        if hasEnded {
            hasEnded = false
            emit(.status(player.timeControlStatus == .paused ? .paused : .playing))
        }
        emit(.currentTime(time))
        return await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
        emit(.rate(rate))
    }

    func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func selectAudioTrack(id: String?) {
        guard let item, let audioGroup else { return }
        item.select(id.flatMap { audioOptions[$0] }, in: audioGroup)
        emit(.selectedAudioTrack(id))
    }

    func selectSubtitleTrack(id: String?) {
        if let legibleGroup, let item {
            item.select(id.flatMap { legibleOptions[$0] }, in: legibleGroup)
        }
        activeSidecarID = sidecars.contains { $0.track.id == id } ? id : nil
        visibleSidecarCueIDs = []
        emit(.subtitleCues([]))
        emit(.selectedSubtitleTrack(id))
        updateSidecarCues(at: player.currentTime().seconds)
    }

    func addExternalSubtitle(_ source: SubtitleSource, title: String, language: String?, select: Bool) async throws -> String? {
        let document = switch source {
        case let .url(url): try await SubtitleDocument.load(from: url)
        case let .text(text, format): SubtitleDocument(contents: text, format: format)
        }
        guard !document.cues.isEmpty else { throw SubtitleDocument.ParseError.noCues }

        nextSidecarNumber += 1
        let track = MediaTrack(
            id: "external-\(nextSidecarNumber)",
            kind: .subtitle,
            title: title,
            language: language,
            isExternal: true,
            codec: source.codec
        )
        sidecars.append((track, document))
        emitTracks()
        if select {
            selectSubtitleTrack(id: track.id)
        }
        return track.id
    }

    func removeExternalSubtitle(id: String) {
        sidecars.removeAll { $0.track.id == id }
        if activeSidecarID == id {
            activeSidecarID = nil
            visibleSidecarCueIDs = []
            emit(.subtitleCues([]))
            emit(.selectedSubtitleTrack(nil))
        }
        emitTracks()
    }

    func shutdown() {
        resetItemState()
        playerCancellables.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        eventHandler = nil
    }

    // MARK: - Observation

    private func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &playerCancellables)
        player.publisher(for: \.volume)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.emit(.volume($0)) }
            .store(in: &playerCancellables)
        player.publisher(for: \.isMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.emit(.muted($0)) }
            .store(in: &playerCancellables)

        let interval = CMTime(seconds: configuration.timeUpdateInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.item else { return }
                self.itemStatusChanged(status, item: item)
            }
            .store(in: &itemCancellables)
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.emit(.duration(duration.isNumeric ? duration.seconds : nil))
            }
            .store(in: &itemCancellables)
        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.emit(.videoSize(size == .zero ? nil : size))
            }
            .store(in: &itemCancellables)
        item.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ranges in
                let end = ranges.map { $0.timeRangeValue.end.seconds }.filter(\.isFinite).max()
                self?.emit(.bufferedTime(end))
            }
            .store(in: &itemCancellables)

        // Combine subscriptions are cancelled automatically when the engine goes away.
        let center = NotificationCenter.default
        center.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.didPlayToEnd() }
            .store(in: &itemCancellables)
        center.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .map { ($0.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                let error = PlaybackError(message ?? "Playback failed", backend: .avFoundation)
                self?.emit(.failed(error, beforeReady: false))
            }
            .store(in: &itemCancellables)
    }

    private func resetItemState() {
        itemCancellables.removeAll()
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        item = nil
        isReady = false
        hasEnded = false
        audioGroup = nil
        legibleGroup = nil
        audioOptions = [:]
        legibleOptions = [:]
        audioTracks = []
        embeddedSubtitleTracks = []
        sidecars = []
        activeSidecarID = nil
        visibleSidecarCueIDs = []
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        switch status {
        case .readyToPlay where !isReady:
            isReady = true
            readyTimeoutTask?.cancel()
            Task { await loadMediaSelection(for: item) }
            if let start = pendingStartTime, start > 0 {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            pendingStartTime = nil
            if autoplay { player.play() }
            updateStatus()
        case .failed:
            let message = item.error?.localizedDescription ?? "The media could not be opened"
            emit(.failed(PlaybackError(message, backend: .avFoundation), beforeReady: !isReady))
        default:
            break
        }
    }

    private func updateStatus() {
        guard item != nil, isReady else { return }
        switch player.timeControlStatus {
        case .playing:
            emit(.buffering(false))
            emit(.status(.playing))
        case .waitingToPlayAtSpecifiedRate:
            emit(.buffering(player.reasonForWaitingToPlay != .noItemToPlay))
            emit(.status(.playing))
        case .paused:
            emit(.buffering(false))
            emit(.status(hasEnded ? .ended : .paused))
        @unknown default:
            break
        }
    }

    private func didPlayToEnd() {
        hasEnded = true
        emit(.status(.ended))
    }

    private func tick(_ time: CMTime) {
        guard time.isNumeric else { return }
        emit(.currentTime(time.seconds))
        updateSidecarCues(at: time.seconds)
    }

    // MARK: - Tracks

    private func loadMediaSelection(for item: AVPlayerItem) async {
        guard let asset = item.asset as? AVURLAsset else { return }
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard item === self.item else { return }

        audioGroup = audible
        legibleGroup = legible
        let audio = await Self.tracks(in: audible, kind: .audio, prefix: "audio")
        let subtitles = await Self.tracks(in: legible, kind: .subtitle, prefix: "subtitle")
        guard item === self.item else { return }
        (audioTracks, audioOptions) = audio
        (embeddedSubtitleTracks, legibleOptions) = subtitles
        emitTracks()

        let selection = item.currentMediaSelection
        if let audible {
            let selected = selection.selectedMediaOption(in: audible)
            emit(.selectedAudioTrack(audioOptions.first { $0.value == selected }?.key))
        }
        if let legible {
            let selected = selection.selectedMediaOption(in: legible)
            emit(.selectedSubtitleTrack(legibleOptions.first { $0.value == selected }?.key))
        }
    }

    private static func tracks(
        in group: AVMediaSelectionGroup?,
        kind: MediaTrack.Kind,
        prefix: String
    ) async -> ([MediaTrack], [String: AVMediaSelectionOption]) {
        guard let group else { return ([], [:]) }
        var tracks: [MediaTrack] = []
        var options: [String: AVMediaSelectionOption] = [:]
        for (index, option) in group.options.enumerated() where !isSynthesizedForcedOption(option, in: group) {
            let id = "\(prefix)-\(index)"
            options[id] = option
            tracks.append(MediaTrack(
                id: id,
                kind: kind,
                // `displayName` is derived from the language; only a real title is a title.
                title: await title(of: option),
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                isDefault: group.defaultOption == option,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isHearingImpaired: option.mediaType == .closedCaption
                    || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility),
                isAudioDescription: option.hasMediaCharacteristic(.describesVideoForAccessibility),
                isExternal: false,
                codec: option.mediaType == .closedCaption ? "cea-608" : nil
            ))
        }
        return (tracks, options)
    }

    /// AVFoundation adds a forced-only twin for every full subtitle track (it shows only the
    /// forced samples). mpv lists tracks as stored, so hide twins of a full track in the same
    /// language. A forced track without a full counterpart stays.
    private static func isSynthesizedForcedOption(_ option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> Bool {
        guard option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) else { return false }
        return group.options.contains { other in
            other !== option
                && !other.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                && other.extendedLanguageTag == option.extendedLanguageTag
                && other.mediaType == option.mediaType
        }
    }

    private static func title(of option: AVMediaSelectionOption) async -> String? {
        let items = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
        guard let item = items.first else { return nil }
        return try? await item.load(.stringValue)
    }

    private func emitTracks() {
        emit(.tracks(audio: audioTracks, subtitles: embeddedSubtitleTracks + sidecars.map(\.track)))
    }

    // MARK: - Subtitles

    private func didReceiveLegible(_ cues: [SubtitleCue]) {
        guard activeSidecarID == nil else { return }
        emit(.subtitleCues(cues))
    }

    private func updateSidecarCues(at time: TimeInterval) {
        guard let activeSidecarID, time.isFinite,
              let document = sidecars.first(where: { $0.track.id == activeSidecarID })?.document
        else { return }
        let cues = document.cues(at: time)
        let ids = cues.map(\.id)
        guard ids != visibleSidecarCueIDs else { return }
        visibleSidecarCueIDs = ids
        emit(.subtitleCues(cues))
    }

    private func emit(_ event: EngineEvent) {
        eventHandler?(event)
    }
}

/// Bridges the legible output delegate (called on the main queue) to the engine.
@MainActor
private final class LegibleOutputReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var onCues: (([SubtitleCue]) -> Void)?

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let start = itemTime.isNumeric ? itemTime.seconds : nil
        let cues = strings.map { string in
            SubtitleCue(
                text: string.string,
                attributedText: SubtitleMarkup.attributedString(fromLegible: string),
                start: start
            )
        }
        MainActor.assumeIsolated {
            onCues?(cues)
        }
    }
}

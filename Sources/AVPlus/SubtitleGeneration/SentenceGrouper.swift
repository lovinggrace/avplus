import Foundation
import NaturalLanguage

/// How a transcript is cut into subtitle cues.
public struct SubtitleSegmentation: Sendable, Hashable {
    /// Language for sentence and word tokenization.
    public var language: NLLanguage
    /// Longest cue text before it is split, roughly two subtitle lines.
    public var maxCharacters: Int
    /// Longest cue duration before it is split.
    public var maxDuration: TimeInterval
    /// Cues are extended to at least this long when the next cue leaves room.
    public var minDuration: TimeInterval
    /// Silence that ends a sentence even when the recognizer added no punctuation.
    public var pauseThreshold: TimeInterval

    public init(
        language: NLLanguage,
        maxCharacters: Int,
        maxDuration: TimeInterval = 7,
        minDuration: TimeInterval = 1,
        pauseThreshold: TimeInterval = 1.2
    ) {
        self.language = language
        self.maxCharacters = maxCharacters
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.pauseThreshold = pauseThreshold
    }

    public static let english = SubtitleSegmentation(language: .english, maxCharacters: 84)
    /// Japanese subtitles conventionally hold about 13–16 full-width characters per line.
    public static let japanese = SubtitleSegmentation(language: .japanese, maxCharacters: 32)

    /// English or Japanese settings, or English-like settings in that locale's language.
    public static func defaults(for locale: Locale) -> SubtitleSegmentation {
        switch locale.language.languageCode?.identifier {
        case "ja": .japanese
        case "en", nil: .english
        case let code?:
            SubtitleSegmentation(
                language: NLLanguage(rawValue: code),
                maxCharacters: unspacedLanguages.contains(code) ? 32 : 84
            )
        }
    }

    /// Scripts written without spaces between words.
    static let unspacedLanguages: Set<String> = ["ja", "zh", "th", "lo", "km", "my", "bo"]

    var usesSpaces: Bool { !Self.unspacedLanguages.contains(language.rawValue) }
}

/// A piece of recognized text with the audio it was heard in, on the media timeline.
struct TranscriptSegment: Sendable, Equatable {
    var text: String
    var start: TimeInterval?
    var end: TimeInterval?

    var isTimed: Bool { start != nil && end != nil }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Turns a stream of timed recognition results into sentence-sized subtitle cues.
///
/// Sentences routinely span several recognition results, so text is accumulated until
/// `NLTokenizer` sees a sentence end (or a long pause / growing length forces one). Every segment
/// keeps its own audio time range, so a cue's timing is exactly the audio of its words.
final class SentenceGrouper {
    let options: SubtitleSegmentation

    /// Text since the last emitted cue.
    private var pending: [TranscriptSegment] = []

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "‼", "⁉", "｡"]
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "】", "»"]
    private static let clauseSeparators: Set<Character> = [",", ";", ":", "、", "，", "；", "：", "—"]

    init(options: SubtitleSegmentation) {
        self.options = options
    }

    /// Adds one final recognition result and returns the cues it completed.
    func append(_ segments: [TranscriptSegment]) -> [SubtitleCue] {
        let incoming = segments.filter { !$0.text.isEmpty }.flatMap(splitIntoWords)
        guard incoming.contains(where: \.hasContent) else { return [] }

        var cues: [SubtitleCue] = []
        if let lastEnd = pending.last(where: \.isTimed)?.end,
           let nextStart = incoming.first(where: \.isTimed)?.start,
           nextStart - lastEnd >= options.pauseThreshold {
            cues += emitSentences(final: true)
        }
        if options.usesSpaces,
           let last = pending.last, last.text.last?.isWhitespace == false,
           let first = incoming.first, first.text.first?.isWhitespace == false {
            pending.append(TranscriptSegment(text: " "))
        }
        pending += incoming
        cues += emitSentences(final: false)
        return cues
    }

    /// Flushes the remaining text at the end of the media.
    func finish() -> [SubtitleCue] {
        emitSentences(final: true)
    }

    /// Enforces ``SubtitleSegmentation/minDuration`` and removes overlaps between cues.
    static func polish(_ cues: [SubtitleCue], minDuration: TimeInterval) -> [SubtitleCue] {
        var cues = cues.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        for index in cues.indices {
            guard let start = cues[index].start, let end = cues[index].end else { continue }
            var newEnd = max(end, start + minDuration)
            if index + 1 < cues.count, let nextStart = cues[index + 1].start, newEnd > nextStart {
                newEnd = max(start, nextStart)
            }
            cues[index].end = newEnd
        }
        return cues
    }

    // MARK: - Sentences

    private func emitSentences(final: Bool) -> [SubtitleCue] {
        let text = pending.map(\.text).joined()
        guard pending.contains(where: \.hasContent) else {
            if final { pending = [] }
            return []
        }

        let boundaries = sentenceBoundaries(in: text)
        var completeBoundaries = boundaries.dropLast()
        if final || isSentenceEnd(text) {
            completeBoundaries = boundaries[...]
        }

        var cues: [SubtitleCue] = []
        var consumed = 0
        for boundary in completeBoundaries {
            cues += makeCues(from: takeSegments(utf16Count: boundary - consumed))
            consumed = boundary
        }

        // Fallback for transcripts without punctuation (common in Japanese): do not let the
        // open sentence grow forever; cut it at the best pause and keep the tail open.
        if !final, exceedsLimits(pending, factor: 2) {
            var pieces = split(pending)
            pending = pieces.removeLast()
            cues += pieces.flatMap { makeCues(from: $0) }
        }
        return cues
    }

    /// UTF-16 offsets where sentences end; whitespace between sentences belongs to the earlier one.
    private func sentenceBoundaries(in text: String) -> [Int] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(options.language)
        tokenizer.string = text
        let starts = tokenizer.tokens(for: text.startIndex..<text.endIndex).map(\.lowerBound)
        var boundaries = starts.dropFirst().map { $0.utf16Offset(in: text) }
        boundaries.append(text.utf16.count)
        return boundaries
    }

    private func isSentenceEnd(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, Self.closingMarks.contains(last) { trimmed.removeLast() }
        return trimmed.last.map(Self.sentenceTerminators.contains) ?? false
    }

    /// Removes and returns the leading segments covering `utf16Count` code units, splitting a
    /// segment that straddles the boundary.
    private func takeSegments(utf16Count: Int) -> [TranscriptSegment] {
        var taken: [TranscriptSegment] = []
        var remaining = utf16Count
        while remaining > 0, !pending.isEmpty {
            let segment = pending.removeFirst()
            let length = segment.text.utf16.count
            if length <= remaining {
                taken.append(segment)
                remaining -= length
            } else {
                let (head, tail) = Self.split(segment, atUTF16Offset: remaining)
                taken.append(head)
                pending.insert(tail, at: 0)
                remaining = 0
            }
        }
        return taken
    }

    // MARK: - Cues

    private func makeCues(from segments: [TranscriptSegment]) -> [SubtitleCue] {
        guard segments.contains(where: \.hasContent) else { return [] }
        guard exceedsLimits(segments, factor: 1), segments.filter(\.hasContent).count > 1 else {
            return makeCue(segments).map { [$0] } ?? []
        }
        return split(segments).flatMap { makeCues(from: $0) }
    }

    private func makeCue(_ segments: [TranscriptSegment]) -> SubtitleCue? {
        guard let start = segments.first(where: { $0.isTimed && $0.hasContent })?.start,
              let end = segments.last(where: { $0.isTimed && $0.hasContent })?.end
        else { return nil }
        let text = Self.normalizedText(segments)
        guard !text.isEmpty else { return nil }
        return SubtitleCue(text: text, start: start, end: max(end, start))
    }

    private func exceedsLimits(_ segments: [TranscriptSegment], factor: Double) -> Bool {
        let characters = Self.normalizedText(segments).count
        if Double(characters) > Double(options.maxCharacters) * factor { return true }
        guard let start = segments.first(where: \.isTimed)?.start,
              let end = segments.last(where: \.isTimed)?.end
        else { return false }
        return end - start > options.maxDuration * factor
    }

    /// Splits at the boundary that best combines a long pause, a clause separator and balance.
    private func split(_ segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        let total = Double(max(1, Self.normalizedText(segments).count))
        var best: (index: Int, score: Double)?
        for index in 1..<segments.count {
            let left = segments[..<index]
            let right = segments[index...]
            guard left.contains(where: \.hasContent), right.contains(where: \.hasContent) else { continue }
            // Between words only: in spaced languages a boundary must touch whitespace.
            if options.usesSpaces,
               left.last?.text.last?.isWhitespace != true, right.first?.text.first?.isWhitespace != true {
                continue
            }
            let leftText = Self.normalizedText(Array(left))
            let balance = 1 - abs(2 * Double(leftText.count) / total - 1)
            var gap = 0.0
            if let leftEnd = left.last(where: \.isTimed)?.end, let rightStart = right.first(where: \.isTimed)?.start {
                gap = max(0, rightStart - leftEnd)
            }
            var punctuation = 0.0
            if let last = leftText.last {
                if Self.sentenceTerminators.contains(last) { punctuation = 2 }
                else if Self.clauseSeparators.contains(last) { punctuation = 1 }
            }
            let score = balance + min(gap, 2) * 2 + punctuation
            if score > (best?.score ?? -.infinity) { best = (index, score) }
        }
        guard let best else { return [segments] }
        return [Array(segments[..<best.index]), Array(segments[best.index...])]
    }

    // MARK: - Segments

    /// Breaks segments longer than a few characters into words with interpolated times, so cues
    /// can be split inside a result that arrived as one run (typical for unspaced scripts).
    private func splitIntoWords(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        guard segment.isTimed, segment.text.count > 8 else { return [segment] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(options.language)
        tokenizer.string = segment.text
        let starts = tokenizer.tokens(for: segment.text.startIndex..<segment.text.endIndex)
            .map { $0.lowerBound.utf16Offset(in: segment.text) }
            .filter { $0 > 0 }
        guard !starts.isEmpty else { return [segment] }

        var pieces: [TranscriptSegment] = []
        var rest = segment
        var consumed = 0
        for offset in starts {
            let (head, tail) = Self.split(rest, atUTF16Offset: offset - consumed)
            pieces.append(head)
            rest = tail
            consumed = offset
        }
        pieces.append(rest)
        return pieces
    }

    /// Splits a segment's text, interpolating its time range by text length.
    static func split(_ segment: TranscriptSegment, atUTF16Offset offset: Int) -> (TranscriptSegment, TranscriptSegment) {
        let utf16 = segment.text.utf16
        let index = utf16.index(utf16.startIndex, offsetBy: min(offset, utf16.count))
        let head = String(segment.text[..<index])
        let tail = String(segment.text[index...])
        guard let start = segment.start, let end = segment.end, utf16.count > 0 else {
            return (TranscriptSegment(text: head, start: segment.start, end: segment.end),
                    TranscriptSegment(text: tail, start: segment.start, end: segment.end))
        }
        // Whitespace carries no audio: the word keeps its full range.
        if head.allSatisfy(\.isWhitespace) {
            return (TranscriptSegment(text: head), TranscriptSegment(text: tail, start: start, end: end))
        }
        if tail.allSatisfy(\.isWhitespace) {
            return (TranscriptSegment(text: head, start: start, end: end), TranscriptSegment(text: tail))
        }
        let middle = start + (end - start) * Double(offset) / Double(utf16.count)
        return (TranscriptSegment(text: head, start: start, end: middle),
                TranscriptSegment(text: tail, start: middle, end: end))
    }

    private static func normalizedText(_ segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

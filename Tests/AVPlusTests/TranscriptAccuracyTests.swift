import Foundation
import Speech
import Testing
@testable import AVPlus

/// Opt-in measurements of transcript accuracy against a reference subtitle file.
struct TranscriptAccuracyTests {
    /// Compares the character error rate of each audio clean-up against a reference subtitle file.
    ///
    ///     ACCURACY_MEDIA=/path/episode.mkv ACCURACY_REFERENCE=/path/episode.srt swift test --filter compareDialogueFocus
    @Test func compareDialogueFocus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let media = environment["ACCURACY_MEDIA"], let reference = environment["ACCURACY_REFERENCE"] else { return }
        let locale = Locale(identifier: environment["ACCURACY_LOCALE"] ?? "ja-JP")
        let expected = Self.comparable(try await SubtitleDocument.load(from: URL(fileURLWithPath: reference)).cues.map(\.text).joined())

        let variants: [(String, SubtitleGenerator.DialogueFocus)] = [
            ("downmix", []), ("centre channel", .centerChannel),
        ]
        let wanted = environment["ACCURACY_VARIANTS"]?.split(separator: ",").map(String.init)
        for (name, focus) in variants where wanted?.contains(name) ?? true {
            let options = SubtitleGenerator.Options(locale: locale, dialogueFocus: focus, store: nil)
            let started = Date()
            // A web address (for example an HLS playlist) is used as it is.
            let source = media.contains("://") ? URL(string: media)! : URL(fileURLWithPath: media)
            let document = try await SubtitleGenerator().generate(for: source, options: options)
            let seconds = Date().timeIntervalSince(started)
            let text = Self.comparable(document.cues.map(\.text).joined())
            let errors = Self.editDistance(expected, text)
            print(String(
                format: "ACCURACY %@: CER %.1f%% (%d of %d), %.1f s",
                name, 100 * Double(errors) / Double(max(expected.count, 1)), errors, expected.count, seconds
            ))
            if let directory = environment["ACCURACY_SAVE"] {
                try document.export(as: .subRip).write(toFile: "\(directory)/\(name).srt", atomically: true, encoding: .utf8)
            }
            if environment["ACCURACY_PRINT"] != nil { print("ACCURACY TEXT \(name): \(document.cues.map(\.text).joined(separator: " / "))") }
        }
    }

    /// How much picking the best of the recognizer's alternatives could gain at most: each result
    /// is matched to its stretch of the reference, and the closest alternative is chosen.
    ///
    ///     ACCURACY_MEDIA=… ACCURACY_REFERENCE=… swift test --filter alternativesUpperBound
    @Test func alternativesUpperBound() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let media = environment["ACCURACY_MEDIA"], let reference = environment["ACCURACY_REFERENCE"] else { return }
        let requested = Locale(identifier: environment["ACCURACY_LOCALE"] ?? "ja-JP")
        let expected = Self.comparable(try await SubtitleDocument.load(from: URL(fileURLWithPath: reference)).cues.map(\.text).joined())
        let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: requested))

        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let options = SubtitleGenerator.Options(locale: locale, store: nil)
        let decoder = try await SubtitleGenerator.makeDecoder(url: URL(fileURLWithPath: media), options: options, sampleRate: format.sampleRate)
        let source = AnalyzerInputSource(decoder: decoder, format: format, activity: SpeechActivityMap(sampleRate: format.sampleRate)) { _ in }
        let results = Task {
            var all: [(best: [Character], candidates: [String], confidence: Double)] = []
            for try await result in transcriber.results where result.isFinal {
                let confidences = result.text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
                let mean = confidences.isEmpty ? 1 : confidences.reduce(0, +) / Double(confidences.count)
                let candidates = ([result.text] + result.alternatives).map { String($0.characters) }
                all.append((Self.comparable(candidates[0]), candidates, mean))
            }
            return all
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let last = try await analyzer.analyzeSequence(AnalyzerInputSequence(source: source)) {
            try await analyzer.finalizeAndFinish(through: last)
        }
        let all = try await results.value

        // Reference position reached at each boundary of the recognized text.
        let recognized = all.flatMap(\.best)
        let boundary = Self.alignment(expected, recognized)
        var offset = 0, topErrors = 0, bestErrors = 0, improved = 0, withDistinct = 0
        var lowTop = 0, lowBest = 0, lowCount = 0
        for result in all {
            let span = Array(expected[boundary[offset]..<boundary[offset + result.best.count]])
            offset += result.best.count
            let distinct = Set(result.candidates.map { String(Self.comparable($0)) })
            if distinct.count > 1 { withDistinct += 1 }
            let top = Self.editDistance(span, result.best)
            let scored = result.candidates.map { (Self.editDistance(span, Self.comparable($0)), $0) }
            let best = scored.min { $0.0 < $1.0 }!
            topErrors += top
            bestErrors += best.0
            if result.confidence < 0.8 { lowCount += 1; lowTop += top; lowBest += best.0 }
            if best.0 < top {
                improved += 1
                if environment["ACCURACY_PRINT"] != nil {
                    print("ACCURACY ALT \(top)->\(best.0) [\(String(format: "%.2f", result.confidence))] ref=\(String(span)) top=\(result.candidates[0]) alt=\(best.1)")
                }
            }
        }
        let total = Double(max(expected.count, 1))
        print(String(format: "ACCURACY alternatives: %d results, %d with a different alternative, %d where one is closer", all.count, withDistinct, improved))
        print(String(format: "ACCURACY alternatives: top choice %.1f%% (%d), best alternative %.1f%% (%d) of %d characters",
                     100 * Double(topErrors) / total, topErrors, 100 * Double(bestErrors) / total, bestErrors, expected.count))
        print(String(format: "ACCURACY alternatives: %d results below 0.8 mean confidence, errors %d -> %d", lowCount, lowTop, lowBest))
    }

    /// For every prefix length of `b`, the length of the prefix of `a` it lines up with.
    private static func alignment(_ a: [Character], _ b: [Character]) -> [Int] {
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for j in 0...b.count { table[j] = Int32(j) }
        for i in 1...max(a.count, 1) where i <= a.count {
            table[i * width] = Int32(i)
            for j in 1..<width {
                let substitution = table[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                table[i * width + j] = min(substitution, table[(i - 1) * width + j] + 1, table[i * width + j - 1] + 1)
            }
        }
        var boundary = [Int](repeating: 0, count: width)
        var i = a.count, j = b.count
        boundary[j] = i
        while j > 0 {
            let here = table[i * width + j]
            if i > 0, here == table[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                i -= 1; j -= 1
                boundary[j] = i
            } else if i > 0, here == table[(i - 1) * width + j] + 1 {
                i -= 1
            } else {
                j -= 1
                boundary[j] = i
            }
        }
        return boundary
    }

    /// Letters and digits only, so punctuation and spacing don't count as errors.
    private static func comparable(_ text: String) -> [Character] {
        text.filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j] + (x == y ? 0 : 1), previous[j + 1] + 1, current[j] + 1)
            }
            previous = current
        }
        return previous[b.count]
    }
}

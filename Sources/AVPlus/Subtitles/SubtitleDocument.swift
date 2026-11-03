import Foundation

/// A parsed sidecar subtitle file (SubRip or WebVTT).
///
/// AVFoundation cannot load sidecar text subtitles, so the AVFoundation backend uses this to
/// serve cues for ``AVPlusPlayer/addSubtitle(url:title:language:select:)``. It is public so apps
/// can parse subtitle files themselves too.
public struct SubtitleDocument: Sendable {
    public enum Format: Sendable {
        case subRip
        case webVTT

        public init?(pathExtension: String) {
            switch pathExtension.lowercased() {
            case "srt": self = .subRip
            case "vtt", "webvtt": self = .webVTT
            default: return nil
            }
        }
    }

    public enum ParseError: Error, Sendable {
        case unsupportedFormat(String)
        case unreadableEncoding
    }

    /// Cues sorted by start time. `start` and `end` are always set.
    public let cues: [SubtitleCue]
    private let longestCueDuration: TimeInterval

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        self.longestCueDuration = cues.map { ($0.end ?? 0) - ($0.start ?? 0) }.max() ?? 0
    }

    /// Parses subtitle text. When `format` is `nil` it is detected from the `WEBVTT` header.
    public init(contents: String, format: Format? = nil) {
        var text = contents
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let resolvedFormat = format ?? (text.hasPrefix("WEBVTT") ? .webVTT : .subRip)
        self.init(cues: Self.parseCues(text, format: resolvedFormat))
    }

    /// Loads and parses a local or remote subtitle file.
    public static func load(from url: URL) async throws -> SubtitleDocument {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            data = try await URLSession.shared.data(from: url).0
        }
        guard let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw ParseError.unreadableEncoding }

        let format = Format(pathExtension: url.pathExtension)
        if format == nil, !url.pathExtension.isEmpty, !contents.hasPrefix("WEBVTT") {
            // Allow extension-less URLs but reject e.g. .ass files we would mangle.
            if !["txt", "sub"].contains(url.pathExtension.lowercased()) {
                throw ParseError.unsupportedFormat(url.pathExtension)
            }
        }
        return SubtitleDocument(contents: contents, format: format)
    }

    /// The cues that should be visible at `time`.
    public func cues(at time: TimeInterval) -> [SubtitleCue] {
        // First cue that starts after `time`.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if (cues[mid].start ?? 0) <= time { low = mid + 1 } else { high = mid }
        }
        var result: [SubtitleCue] = []
        var index = low - 1
        while index >= 0, let start = cues[index].start, start >= time - longestCueDuration {
            if let end = cues[index].end, time < end { result.append(cues[index]) }
            index -= 1
        }
        return result.reversed()
    }

    // MARK: - Parsing

    private static func parseCues(_ text: String, format: Format) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if format == .webVTT, let first = lines.first,
               first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }
            guard let (start, end) = parseTiming(lines[timingIndex]) else { continue }
            let body = lines[lines.index(after: timingIndex)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let attributed = SubtitleMarkup.attributedString(from: body)
            cues.append(SubtitleCue(
                text: String(attributed.characters),
                attributedText: attributed,
                start: start,
                end: end
            ))
        }
        return cues
    }

    private static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // WebVTT cue settings follow the end timestamp after whitespace.
        let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = parseTimestamp(endToken),
              end > start
        else { return nil }
        return (start, end)
    }

    /// Parses `hh:mm:ss,mmm`, `hh:mm:ss.mmm` or `mm:ss.mmm`.
    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let normalized = string.replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":")
        guard (2...3).contains(components.count) else { return nil }
        var total: TimeInterval = 0
        for component in components {
            guard let value = Double(component) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

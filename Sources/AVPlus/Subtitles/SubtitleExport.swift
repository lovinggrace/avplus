import Foundation

extension SubtitleDocument {
    /// Serializes the cues as SubRip or WebVTT text. Styling is not preserved; cues without
    /// timing are skipped.
    public func export(as format: Format) -> String {
        let timedCues = cues.filter { $0.start != nil && $0.end != nil }
        switch format {
        case .subRip:
            return timedCues.enumerated().map { index, cue in
                "\(index + 1)\n\(Self.timestamp(cue.start!, separator: ",")) --> \(Self.timestamp(cue.end!, separator: ","))\n\(Self.cueBody(cue.text))\n"
            }
            .joined(separator: "\n")
        case .webVTT:
            let body = timedCues.map { cue in
                let text = Self.cueBody(cue.text)
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "\(Self.timestamp(cue.start!, separator: ".")) --> \(Self.timestamp(cue.end!, separator: "."))\n\(text)\n"
            }
            return (["WEBVTT\n"] + body).joined(separator: "\n")
        }
    }

    /// Writes the document as SubRip or WebVTT. Without `format`, the file extension decides
    /// (`.srt` or `.vtt`).
    public func write(to url: URL, format: Format? = nil) throws {
        guard let format = format ?? Format(pathExtension: url.pathExtension) else {
            throw ParseError.unsupportedFormat(url.pathExtension)
        }
        try Data(export(as: format).utf8).write(to: url, options: .atomic)
    }

    private static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60000 % 60
        let secs = milliseconds / 1000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, milliseconds % 1000)
    }

    /// Blank lines end a cue in both formats.
    private static func cueBody(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n")
    }
}

extension SubtitleDocument: Codable {
    private struct StoredCue: Codable {
        var start: TimeInterval?
        var end: TimeInterval?
        var text: String
    }

    public init(from decoder: any Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([StoredCue].self)
        self.init(cues: stored.map { SubtitleCue(text: $0.text, start: $0.start, end: $0.end) })
    }

    /// Encodes timing and plain text; styling is not part of the stored form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cues.map { StoredCue(start: $0.start, end: $0.end, text: $0.text) })
    }
}

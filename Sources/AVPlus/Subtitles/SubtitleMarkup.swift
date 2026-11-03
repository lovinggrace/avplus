import CoreMedia
import Foundation
import SwiftUI

/// Converts the various subtitle styling representations into `AttributedString`.
enum SubtitleMarkup {
    private struct Style {
        var italic = false
        var bold = false
        var underline = false
        var color: Color?
    }

    /// Converts SubRip / WebVTT inline markup (`<i>`, `<b>`, `<u>`, `<font color>`, `<c>`, `<v>`,
    /// `{\i1}` ASS overrides) into styled text. Unknown tags are dropped.
    static func attributedString(from markup: String) -> AttributedString {
        var result = AttributedString()
        var stack: [(tag: String, style: Style)] = []
        var current = Style()
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(decodeEntities(buffer))
            var intent: InlinePresentationIntent = []
            if current.italic { intent.insert(.emphasized) }
            if current.bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if current.underline { run.underlineStyle = .single }
            if let color = current.color { run.foregroundColor = color }
            result += run
            buffer = ""
        }

        var index = markup.startIndex
        while index < markup.endIndex {
            let character = markup[index]
            if character == "<", let close = markup[index...].firstIndex(of: ">") {
                flush()
                let tag = markup[markup.index(after: index)..<close].trimmingCharacters(in: .whitespaces)
                if tag.hasPrefix("/") {
                    let name = tagName(String(tag.dropFirst()))
                    if let match = stack.lastIndex(where: { $0.tag == name }) {
                        current = stack[match].style
                        stack.removeSubrange(match...)
                    }
                } else {
                    let name = tagName(tag)
                    stack.append((name, current))
                    switch name {
                    case "i": current.italic = true
                    case "b": current.bold = true
                    case "u": current.underline = true
                    case "font":
                        if let value = attribute("color", in: tag) { current.color = color(from: value) }
                    default: break // <c.class>, <v Speaker>, <lang>, <ruby>, timestamps…
                    }
                    // Timestamp tags (`<00:00:01.000>`) and other void tags never close.
                    if name.first?.isNumber == true { stack.removeLast() }
                }
                index = markup.index(after: close)
            } else if character == "{", markup[index...].hasPrefix("{\\"),
                      let close = markup[index...].firstIndex(of: "}") {
                flush()
                // Minimal ASS override support, as commonly found in SRT files.
                let overrides = markup[index..<close]
                if overrides.contains("\\i1") { current.italic = true }
                if overrides.contains("\\i0") { current.italic = false }
                if overrides.contains("\\b1") { current.bold = true }
                if overrides.contains("\\b0") { current.bold = false }
                if overrides.contains("\\u1") { current.underline = true }
                if overrides.contains("\\u0") { current.underline = false }
                index = markup.index(after: close)
            } else {
                buffer.append(character)
                index = markup.index(after: index)
            }
        }
        flush()
        return result
    }

    /// Converts an attributed string from `AVPlayerItemLegibleOutput`, whose attributes use the
    /// `kCMTextMarkupAttribute_*` keys, into styled text.
    static func attributedString(fromLegible string: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        let fullRange = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var run = AttributedString(string.attributedSubstring(from: range).string)
            var intent: InlinePresentationIntent = []
            if attributes[NSAttributedString.Key(kCMTextMarkupAttribute_ItalicStyle as String)] as? Bool == true {
                intent.insert(.emphasized)
            }
            if attributes[NSAttributedString.Key(kCMTextMarkupAttribute_BoldStyle as String)] as? Bool == true {
                intent.insert(.stronglyEmphasized)
            }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if attributes[NSAttributedString.Key(kCMTextMarkupAttribute_UnderlineStyle as String)] as? Bool == true {
                run.underlineStyle = .single
            }
            if let argb = attributes[NSAttributedString.Key(kCMTextMarkupAttribute_ForegroundColorARGB as String)] as? [NSNumber],
               argb.count == 4 {
                run.foregroundColor = Color(
                    .sRGB,
                    red: argb[1].doubleValue,
                    green: argb[2].doubleValue,
                    blue: argb[3].doubleValue,
                    opacity: argb[0].doubleValue
                )
            }
            result += run
        }
        return result
    }

    private static func tagName(_ tag: String) -> String {
        let end = tag.firstIndex(where: { $0 == " " || $0 == "." }) ?? tag.endIndex
        return tag[..<end].lowercased()
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let value = tag[range.upperBound...].drop { $0 == "\"" || $0 == "'" }
        return String(value.prefix { $0 != "\"" && $0 != "'" && $0 != " " })
    }

    private static func color(from value: String) -> Color? {
        var hex = value.lowercased()
        let named: [String: Color] = [
            "white": .white, "black": .black, "red": .red, "green": .green, "blue": .blue,
            "yellow": .yellow, "cyan": .cyan, "magenta": .pink, "orange": .orange, "gray": .gray, "grey": .gray,
        ]
        if let color = named[hex] { return color }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    private static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

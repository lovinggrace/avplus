import Foundation
import Testing
@testable import AVPlus

struct SubtitleParsingTests {
    @Test func parsesSubRip() throws {
        let document = SubtitleDocument(contents: """
        1
        00:00:01,000 --> 00:00:02,500
        Hello <i>world</i>

        2
        00:00:03,000 --> 00:00:04,000
        Two
        lines
        """)

        #expect(document.cues.count == 2)
        let first = try #require(document.cues.first)
        #expect(first.text == "Hello world")
        #expect(first.start == 1)
        #expect(first.end == 2.5)
        #expect(document.cues[1].text == "Two\nlines")

        let italicRuns = first.attributedText.runs.filter { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        #expect(italicRuns.map { String(first.attributedText[$0.range].characters) } == ["world"])
    }

    @Test func parsesWebVTTWithHeaderNotesAndSettings() {
        let document = SubtitleDocument(contents: """
        WEBVTT - Example

        NOTE this block is ignored

        intro
        00:01.000 --> 00:02.000 align:start line:0
        <v Roger>Hi &amp; welcome</v>

        01:00:00.000 --> 01:00:01.500
        <c.yellow>Late</c>
        """)

        #expect(document.cues.map(\.text) == ["Hi & welcome", "Late"])
        #expect(document.cues.first?.start == 1)
        #expect(document.cues.last?.start == 3600)
    }

    @Test func handlesCRLFAndBOM() {
        let document = SubtitleDocument(contents: "\u{FEFF}1\r\n00:00:00,000 --> 00:00:01,000\r\nLine\r\n\r\n")
        #expect(document.cues.map(\.text) == ["Line"])
    }

    @Test func looksUpCuesAtTime() {
        let document = SubtitleDocument(cues: [
            SubtitleCue(text: "A", start: 0, end: 10),
            SubtitleCue(text: "B", start: 2, end: 3),
            SubtitleCue(text: "C", start: 11, end: 12),
        ])

        #expect(document.cues(at: 2.5).map(\.text) == ["A", "B"])
        #expect(document.cues(at: 5).map(\.text) == ["A"])
        #expect(document.cues(at: 10.5).isEmpty)
        #expect(document.cues(at: 11).map(\.text) == ["C"])
        #expect(document.cues(at: -1).isEmpty)
    }

    @Test func convertsMarkup() {
        let styled = SubtitleMarkup.attributedString(from: "{\\i1}lean{\\i0} <b>bold</b> <font color=\"#ff0000\">red</font> &lt;3")
        #expect(String(styled.characters) == "lean bold red <3")
        let bold = styled.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(styled[$0.range].characters) } == ["bold"])
        #expect(styled.runs.contains { $0.foregroundColor != nil })
    }

    @Test func parsesTimestamps() {
        #expect(SubtitleDocument.parseTimestamp("01:02:03,450") == 3723.45)
        #expect(SubtitleDocument.parseTimestamp("02:03.5") == 123.5)
        #expect(SubtitleDocument.parseTimestamp("nope") == nil)
    }
}

struct MPVTrackListTests {
    @Test func decodesTrackList() throws {
        let json = """
        [{"id":1,"type":"video","selected":true,"codec":"vp9"},
         {"id":1,"type":"audio","lang":"eng","title":"Main","default":true,"selected":true,"codec":"opus"},
         {"id":2,"type":"audio","lang":"deu","selected":false},
         {"id":1,"type":"sub","lang":"eng","forced":false,"external":false,"selected":true,"codec":"subrip"},
         {"id":2,"type":"sub","title":"Signs","forced":true,"external":true,"selected":false}]
        """
        let list = try MPVTrackList(json: json)

        #expect(list.audioTracks.map(\.id) == ["1", "2"])
        #expect(list.audioTracks.first?.isDefault == true)
        #expect(list.subtitleTracks.map(\.language) == ["eng", nil])
        #expect(list.subtitleTracks.last?.isForced == true)
        #expect(list.subtitleTracks.last?.isExternal == true)
        #expect(list.selectedAudioID == "1")
        #expect(list.selectedSubtitleID == "1")
    }
}

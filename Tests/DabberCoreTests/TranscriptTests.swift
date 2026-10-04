import Foundation
import Testing
@testable import DabberCore

private func w(_ text: String, _ start: Int, _ end: Int, _ confidence: Double = 1) -> SpokenWord {
    SpokenWord(startMillis: start, endMillis: end, text: text, confidence: confidence)
}

struct TranscriptTests {
    @Test func unsureLinesAreDropped() {
        let lines = Transcript.lines([w("I've", 0, 300, 0.5), w("got", 350, 600, 0.5), w("Да", 2_600, 2_900, 0.95), w("хорошо", 2_950, 3_300, 0.9)], speaker: "Я")
        #expect(lines.map(\.text) == ["Да хорошо"])
    }

    @Test func aRealShortReplyAt067IsKeptAndInventedLinesAt055AreNot() {
        let lines = Transcript.lines([w("так", 22_240, 22_400, 0.49), w("попробуем.", 22_400, 25_840, 0.85),
                                      w("No,", 30_000, 30_300, 0.55), w("it's", 30_350, 30_600, 0.55)], speaker: "Я")
        #expect(lines.map(\.text) == ["так попробуем."])
    }

    @Test func anUnsureSentenceEndDoesNotLeakIntoTheNextLine() {
        let lines = Transcript.lines([w("Maybe", 0, 500, 0.5), w("so.", 600, 1_200, 0.5), w("Да", 1_500, 1_800, 0.95)], speaker: "Я")
        #expect(lines.map(\.text) == ["Да"])
    }

    @Test func oneUnsureWordDoesNotDropASureLine() {
        let lines = Transcript.lines([w("Как", 0, 300, 1), w("дела", 350, 600, 0.3), w("сегодня", 650, 1_000, 1)], speaker: "Я")
        #expect(lines.map(\.text) == ["Как дела сегодня"])
    }

    @Test func wordsJoinIntoOneLineUntilAPause() {
        let lines = Transcript.lines([w("Все", 0, 300), w("в", 350, 400), w("сборе", 450, 900), w("Да", 2_500, 2_800)], speaker: "Я")
        #expect(lines == [
            TranscriptLine(startMillis: 0, endMillis: 900, speaker: "Я", text: "Все в сборе"),
            TranscriptLine(startMillis: 2_500, endMillis: 2_800, speaker: "Я", text: "Да"),
        ])
    }

    @Test func aSentenceEndClosesALineOfAtLeastOneSecond() {
        let lines = Transcript.lines([w("Привет.", 0, 400), w("Как", 450, 700), w("дела?", 750, 1_200), w("Норм", 1_250, 1_500)], speaker: "Я")
        #expect(lines.map(\.text) == ["Привет. Как дела?", "Норм"])
    }

    @Test func aLongLineIsCutAt84Characters() {
        let words = (0..<30).map { w("слово", $0 * 300, $0 * 300 + 250) }
        let lines = Transcript.lines(words, speaker: "Я")
        #expect(lines.allSatisfy { $0.text.count <= Transcript.maxChars })
        #expect(lines.map(\.text).joined(separator: " ") == Array(repeating: "слово", count: 30).joined(separator: " "))
        #expect(lines.map { $0.text.count } == [83, 83, 11])
    }

    @Test func aLineOfExactly84CharactersStaysOneLine() {
        let words = (0..<11).map { w("abcdef", $0 * 300, $0 * 300 + 250) } + [w("abcdefg", 3_300, 3_550)]
        let lines = Transcript.lines(words, speaker: "Я")
        #expect(lines.count == 1)
        #expect(lines.first?.text.count == 84)
    }

    @Test func outOfOrderAndZeroLengthWordsNeverGiveEmptyOrInvertedLines() {
        #expect(Transcript.lines([w("а", 5_000, 5_500), w("б", 5_600, 1_200)], speaker: "Я")
            == [TranscriptLine(startMillis: 5_000, endMillis: 5_500, speaker: "Я", text: "а б")])
        #expect(Transcript.lines([w("Да", 1_000, 1_000)], speaker: "Я")
            == [TranscriptLine(startMillis: 1_000, endMillis: 1_001, speaker: "Я", text: "Да")])
    }

    @Test func blankWordsAreSkipped() {
        #expect(Transcript.lines([w(" ", 0, 100), w("Да", 200, 400)], speaker: "Я").map(\.text) == ["Да"])
    }

    @Test func tracksMergeByStartTimeAndTheTextShowsMarks() {
        let me = [TranscriptLine(startMillis: 1_000, endMillis: 2_000, speaker: "Я", text: "Привет")]
        let others = [TranscriptLine(startMillis: 0, endMillis: 900, speaker: "Собеседники", text: "Начнём"),
                      TranscriptLine(startMillis: 61_000, endMillis: 62_000, speaker: "Собеседники", text: "Пока")]
        let merged = Transcript.merge([me, others])
        #expect(merged.map(\.text) == ["Начнём", "Привет", "Пока"])
        let marks = [Mark(id: 1, offsetNanos: 60_000_000_000, text: "про деньги")]
        #expect(Transcript.text(merged, marks: marks) == """
            [00:00:00] Собеседники: Начнём
            [00:00:01] Я: Привет
            — про деньги —
            [00:01:01] Собеседники: Пока

            """)
    }

    @Test func srtNumbersCuesFromOne() {
        let lines = [TranscriptLine(startMillis: 1_500, endMillis: 3_250, speaker: "Я", text: "Привет")]
        #expect(Transcript.srt(lines) == "1\n00:00:01,500 --> 00:00:03,250\nЯ: Привет\n\n")
    }
}

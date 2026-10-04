import Foundation
import Testing
@testable import DabberCore

private func w(_ text: String, _ start: Int, _ end: Int) -> SpokenWord {
    SpokenWord(startMillis: start, endMillis: end, text: text)
}

struct TranscriptTests {
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

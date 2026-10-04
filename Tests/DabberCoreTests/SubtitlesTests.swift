import Testing
@testable import DabberCore

private func line(_ speaker: String, _ text: String, _ start: Int, _ end: Int) -> TranscriptLine {
    TranscriptLine(startMillis: start, endMillis: end, speaker: speaker, text: text)
}

struct SubtitlesTests {
    @Test func separateLinesBecomeSeparateCuesWithSpeakers() {
        let cues = Subtitles.cues([line("Я", "Привет", 0, 1_000), line("Собеседники", "Здравствуйте", 2_000, 3_000)])
        #expect(cues == [
            SubtitleCue(startMillis: 0, endMillis: 1_000, text: "Я: Привет"),
            SubtitleCue(startMillis: 2_000, endMillis: 3_000, text: "Собеседники: Здравствуйте"),
        ])
    }

    @Test func overlappingSpeakersShareACue() {
        let cues = Subtitles.cues([line("Я", "Привет", 0, 2_000), line("Собеседники", "Да", 1_000, 3_000)])
        #expect(cues == [
            SubtitleCue(startMillis: 0, endMillis: 1_000, text: "Я: Привет"),
            SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Привет\nСобеседники: Да"),
            SubtitleCue(startMillis: 2_000, endMillis: 3_000, text: "Собеседники: Да"),
        ])
    }

    @Test func aShortGapIsCoveredByThePreviousCue() {
        let cues = Subtitles.cues([line("Я", "Раз", 0, 1_000), line("Я", "Два", 1_100, 2_000)])
        #expect(cues == [
            SubtitleCue(startMillis: 0, endMillis: 1_100, text: "Я: Раз"),
            SubtitleCue(startMillis: 1_100, endMillis: 2_000, text: "Я: Два"),
        ])
    }

    @Test func aShortOverlapIsFoldedIntoThePreviousCue() {
        let cues = Subtitles.cues([line("Я", "Раз", 0, 1_000), line("Собеседники", "Два", 900, 2_000)])
        #expect(cues == [
            SubtitleCue(startMillis: 0, endMillis: 1_000, text: "Я: Раз"),
            SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Собеседники: Два"),
        ])
    }

    @Test func noCueIsShorterThanTheMinimum() {
        let cues = Subtitles.cues([line("Я", "Да", 5_000, 5_100), line("Я", "Нет", 9_000, 10_000)])
        #expect(cues.first == SubtitleCue(startMillis: 5_000, endMillis: 5_300, text: "Я: Да"))
        #expect(cues.allSatisfy { $0.endMillis - $0.startMillis >= Subtitles.minMillis })
    }

    @Test func noLinesNoCues() {
        #expect(Subtitles.cues([]).isEmpty)
    }
}

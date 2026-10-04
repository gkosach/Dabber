import Testing
@testable import DabberCore

struct SubtitleTrackTests {
    private func spans(_ cues: [SubtitleCue], _ end: Int) -> [String] {
        SubtitleTrack.spans(cues, endMillis: end).map { "\($0.start)-\($0.end) \($0.text)" }
    }

    @Test func aFirstCueCloseToZeroStartsTheTrackAtZero() {
        #expect(spans([SubtitleCue(startMillis: 150, endMillis: 1_000, text: "A")], 3_000) == ["0-1000 A", "1000-3000 "])
    }

    @Test func aCueRunningPastTheAudioIsCutAtTheEnd() {
        #expect(spans([SubtitleCue(startMillis: 2_500, endMillis: 3_250, text: "A")], 3_000) == ["0-2500 ", "2500-3000 A"])
    }

    @Test func aShortGapGoesToThePreviousSampleAndAShortTailIsNotWritten() {
        let cues = [SubtitleCue(startMillis: 0, endMillis: 1_000, text: "A"), SubtitleCue(startMillis: 1_100, endMillis: 2_000, text: "B")]
        #expect(spans(cues, 2_100) == ["0-1100 A", "1100-2000 B"])
    }

    @Test func nothingIsWrittenWithoutRoomForACue() {
        #expect(spans([SubtitleCue(startMillis: 0, endMillis: 150, text: "A")], 200).isEmpty)
        #expect(spans([], 3_000).isEmpty)
    }
}

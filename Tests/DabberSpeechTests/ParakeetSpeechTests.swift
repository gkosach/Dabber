import FluidAudio
import Testing
import DabberCore
@testable import DabberSpeech

struct ParakeetSpeechTests {
    private func t(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }

    @Test func tokensWithALeadingSpaceStartNewWords() {
        let words = ParakeetSpeech.words([t(" При", 0.1, 0.2), t("вет", 0.2, 0.4), t(" USD", 1.0, 1.2), t("T", 1.2, 1.3)])
        #expect(words == [
            SpokenWord(startMillis: 100, endMillis: 400, text: "Привет"),
            SpokenWord(startMillis: 1_000, endMillis: 1_300, text: "USDT"),
        ])
    }

    @Test func noTokensNoWords() {
        #expect(ParakeetSpeech.words([]).isEmpty)
    }
}

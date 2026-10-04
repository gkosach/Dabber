import Foundation
import Testing
@testable import DabberCore

private func w(_ text: String, _ start: Int, _ confidence: Double = 1) -> SpokenWord {
    SpokenWord(startMillis: start, endMillis: start + 200, text: text, confidence: confidence)
}

struct EchoTests {
    /// Recording 2026-10-04 23-23: a laptop mic on speakers heard a YouTube video, then the user replied.
    @Test func macAudioHeardThroughTheSpeakersIsLeftOutOfTheMicWords() {
        let mic = [w("And", 18_240, 0.29), w("all", 18_640, 0.99), w("its", 18_960, 0.94), w("incidents,", 19_120, 0.73),
                   w("great", 19_760, 0.75), w("and", 20_080, 0.99), w("small,", 20_240, 0.86), w("is", 20_880, 0.74),
                   w("так", 22_240, 0.49), w("попробуем.", 22_400, 0.85)]
        let heard = [w("in", 18_300), w("all", 18_560), w("its", 18_880), w("incidents,", 19_040), w("great", 19_680),
                     w("and", 20_000), w("small,", 20_160), w("is", 20_800)]
        let kept = Transcript.withoutEcho(mic, heard: heard)
        #expect(kept.map(\.text) == ["And", "так", "попробуем."])
        #expect(Transcript.lines(kept, speaker: Transcript.me).map(\.text) == ["так попробуем."])
    }

    @Test func aLoneWordThatHappensToMatchIsKept() {
        let mic = [w("Ну", 1_000), w("да", 1_300), w("конечно", 1_600)]
        let heard = [w("да", 1_200), w("именно", 1_500)]
        #expect(Transcript.withoutEcho(mic, heard: heard).map(\.text) == ["Ну", "да", "конечно"])
    }

    @Test func matchingWordsMoreThanOneAndAHalfSecondsAwayAreKept() {
        let mic = [w("great", 10_000), w("and", 10_300), w("small", 10_600)]
        let heard = [w("great", 8_400), w("and", 11_900), w("small", 12_200)]
        #expect(Transcript.withoutEcho(mic, heard: heard).map(\.text) == ["great", "and", "small"])
        let near = [w("great", 8_500), w("and", 11_800), w("small", 12_100)]
        #expect(Transcript.withoutEcho(mic, heard: near).isEmpty)
    }

    @Test func casePunctuationAndYoDoNotMatter() {
        let mic = [w("Всё,", 1_000), w("ЕЩЁ", 1_300), w("man's", 1_600)]
        let heard = [w("все", 1_000), w("ещё.", 1_300), w("Mans!", 1_600)]
        #expect(Transcript.withoutEcho(mic, heard: heard).isEmpty)
        #expect(Transcript.withoutEcho([w("—", 1_000), w("...", 1_300)], heard: [w("—", 1_000), w("...", 1_300)]).count == 2)
    }

    @Test func withoutMacAudioTheMicWordsStayAsTheyAre() {
        let mic = [w("great", 1_000), w("and", 1_300)]
        #expect(Transcript.withoutEcho(mic, heard: []) == mic)
    }
}

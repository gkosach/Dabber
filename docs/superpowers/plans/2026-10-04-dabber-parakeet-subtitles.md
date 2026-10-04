# Transcript and Subtitles (Parakeet via FluidAudio) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every finished recording gets `transcript.txt` and `transcript.srt` next to it, and the slides video gets a Russian subtitle track that is off by default and can be turned on in QuickTime Player (View > Subtitles).

**Architecture:** Transcription is one step inside `Finalizer.run`, after the per-track AAC files are written and before the slides video is built, so the subtitles go into the mp4 in the same pass. `DabberCore` stays free of ML code: it takes a `SpeechToText` closure (audio file in, timed words out). A new target `DabberSpeech` implements that closure with FluidAudio (Parakeet TDT 0.6B v3, CoreML on the Neural Engine), and only the app target links it. Each track is transcribed on its own: mic tracks are labelled «Я», computer audio «Собеседники». A transcription failure never blocks the recording: the report gets `transcriptError` and the menu shows it.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetWriter`, tx3g subtitle track), FluidAudio 0.17.5 (Apache-2.0), Parakeet TDT 0.6B v3 CoreML model (CC-BY-4.0), Swift Testing.

**Facts this plan relies on (checked in a spike on 2026-10-04, M5 MacBook Air):**
- `fluidaudiocli transcribe` on a 24-minute meeting: 5.5 s warm, 116 s on first use (model download 469 MB + ANE compile). Russian quality judged good by the user.
- No language hint is better for this user: with `--language ru` all English terms became Cyrillic («Байбит»); without it the output keeps `USDT`, `KYC`, `Earn`, `Binance`.
- An `AVAssetWriterInput(mediaType: .subtitle)` with a `tx3g` format (`kCMMediaType_Subtitle` / `kCMSubtitleFormatType_3GText`), `languageCode = "rus"`, shows up in QuickTime's Subtitles menu (user confirmed). AVFoundation lists it as `["Russian", "Russian Forced"]`.
- Gaps must be filled with empty samples, otherwise a cue stays on screen until the next one. A sample with (near) zero duration makes the whole write fail with `-16364`, so no sample may be shorter than 300 ms; short gaps are merged into the neighbouring cue.

**Test runs:** the user's Mac must stay responsive. Run only the suite you touched: `scripts/test.sh --filter <Suite>`. Run the full suite once, at the end (Task 8).

---

## File Structure

- Create `Sources/DabberCore/Transcribe/Transcript.swift` — `SpokenWord`, `TranscriptLine`, `SpeechToText`; grouping words into lines, merging tracks, `.txt` and `.srt` rendering.
- Create `Sources/DabberCore/Transcribe/Subtitles.swift` — `SubtitleCue` and `Subtitles.cues(_:)`: non-overlapping cues with speaker prefixes, no cue shorter than 300 ms.
- Create `Sources/DabberCore/Finalize/SubtitleTrack.swift` — the tx3g subtitle lane for `AVAssetWriter`.
- Modify `Sources/DabberCore/Finalize/ChapterWriter.swift` — share the text sample and format code with the subtitle lane.
- Modify `Sources/DabberCore/Finalize/SlideshowWriter.swift` — accept subtitle cues.
- Modify `Sources/DabberCore/Finalize/Finalizer.swift` — the transcription step; `speech` parameter on `run`, `finish`, `recoverAll`.
- Modify `Sources/DabberCore/Finalize/Delivery.swift` — pass `speech` through.
- Modify `Sources/DabberCore/Model/SessionManifest.swift` — `FinalizeReport.transcriptError`.
- Modify `Sources/DabberCore/App/RecorderModel.swift` — show `transcriptError` in the menu warnings.
- Create `Sources/DabberSpeech/ParakeetSpeech.swift` — FluidAudio adapter.
- Modify `Package.swift` — FluidAudio dependency, `DabberSpeech` target and its tests.
- Modify `Sources/Dabber/AppDelegate.swift`, `Sources/Dabber/Headless.swift` — wire `ParakeetSpeech.shared.transcribe`.
- Create tests: `Tests/DabberCoreTests/TranscriptTests.swift`, `Tests/DabberCoreTests/SubtitlesTests.swift`, `Tests/DabberSpeechTests/ParakeetSpeechTests.swift`; extend `Tests/DabberCoreTests/FinalizerTests.swift`.
- Modify `README.md`, `README.ru.md`, `docs/backlog.md`.

---

### Task 1: Transcript lines from timed words

**Files:**
- Create: `Sources/DabberCore/Transcribe/Transcript.swift`
- Test: `Tests/DabberCoreTests/TranscriptTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

`Mark(id:offsetNanos:text:)` and `Mark.title(number:)` (text if set, else «Mark N») are in `Sources/DabberCore/Model/Mark.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter TranscriptTests`
Expected: build error, `cannot find 'Transcript' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/DabberCore/Transcribe/Transcript.swift`:

```swift
import Foundation

public struct SpokenWord: Equatable, Sendable {
    public let startMillis: Int
    public let endMillis: Int
    public let text: String

    public init(startMillis: Int, endMillis: Int, text: String) {
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.text = text
    }
}

/// Turns one audio file into timed words. Blocking: Finalizer runs on a background queue.
public typealias SpeechToText = @Sendable (URL) throws -> [SpokenWord]

public struct TranscriptLine: Equatable, Sendable {
    public let startMillis: Int
    public let endMillis: Int
    public let speaker: String
    public let text: String

    public init(startMillis: Int, endMillis: Int, speaker: String, text: String) {
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.speaker = speaker
        self.text = text
    }
}

public enum Transcript {
    public static let me = "Я"
    public static let others = "Собеседники"
    public static let textFile = "transcript.txt"
    public static let srtFile = "transcript.srt"
    static let pauseMillis = 1_000
    static let maxChars = 84

    public static func lines(_ words: [SpokenWord], speaker: String) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        for w in words {
            let word = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if let c = current, w.startMillis - c.endMillis < pauseMillis, c.text.count + 1 + word.count <= maxChars {
                current = TranscriptLine(startMillis: c.startMillis, endMillis: w.endMillis, speaker: speaker, text: c.text + " " + word)
            } else {
                if let c = current { out.append(c) }
                current = TranscriptLine(startMillis: w.startMillis, endMillis: w.endMillis, speaker: speaker, text: word)
            }
            if let c = current, c.endMillis - c.startMillis >= 1_000, let last = word.last, ".?!".contains(last) {
                out.append(c)
                current = nil
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    public static func merge(_ tracks: [[TranscriptLine]]) -> [TranscriptLine] {
        let all = tracks.flatMap { $0 }
        return all.indices.sorted { (all[$0].startMillis, $0) < (all[$1].startMillis, $1) }.map { all[$0] }
    }

    public static func text(_ lines: [TranscriptLine], marks: [Mark]) -> String {
        var pending = Chapters.marks(marks, durationMillis: Int.max)[...]
        var out = ""
        for line in lines {
            while let mark = pending.first, mark.startMillis <= line.startMillis {
                out += "— \(mark.title) —\n"
                pending.removeFirst()
            }
            out += "[\(clock(line.startMillis))] \(line.speaker): \(line.text)\n"
        }
        for mark in pending { out += "— \(mark.title) —\n" }
        return out
    }

    public static func srt(_ lines: [TranscriptLine]) -> String {
        lines.enumerated().map { i, line in
            "\(i + 1)\n\(timecode(line.startMillis)) --> \(timecode(line.endMillis))\n\(line.speaker): \(line.text)\n\n"
        }.joined()
    }

    private static func clock(_ millis: Int) -> String {
        let s = millis / 1000
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    private static func timecode(_ millis: Int) -> String {
        clock(millis) + String(format: ",%03d", millis % 1000)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter TranscriptTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Transcribe/Transcript.swift Tests/DabberCoreTests/TranscriptTests.swift
git commit -m "feat: group timed words into transcript lines with speakers, txt and srt"
```

---

### Task 2: Subtitle cues without overlaps or tiny samples

**Files:**
- Create: `Sources/DabberCore/Transcribe/Subtitles.swift`
- Test: `Tests/DabberCoreTests/SubtitlesTests.swift`

Rules: one cue shows every line active in its time span, one line per speaker, prefixed with the speaker. Adjacent spans with the same text become one cue. A span shorter than `minMillis` (300 ms) is folded into the previous cue; an empty gap shorter than `minMillis` extends the previous cue. A cue still shorter than `minMillis` that is directly followed by a longer span is taken over by that span (it keeps its start, gets the new text). Any other cue still shorter than `minMillis` is stretched to `minMillis` or up to the next cue.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter SubtitlesTests`
Expected: build error, `cannot find 'Subtitles' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/DabberCore/Transcribe/Subtitles.swift`:

```swift
public struct SubtitleCue: Equatable, Sendable {
    public let startMillis: Int
    public var endMillis: Int
    public let text: String

    public init(startMillis: Int, endMillis: Int, text: String) {
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.text = text
    }
}

public enum Subtitles {
    /// AVAssetWriter fails the whole mp4 (-16364) on near-zero subtitle samples; nothing shorter than this is written.
    public static let minMillis = 300

    public static func cues(_ lines: [TranscriptLine]) -> [SubtitleCue] {
        let cuts = Set(lines.flatMap { [$0.startMillis, $0.endMillis] }).sorted()
        var out: [SubtitleCue] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let text = lines.filter { $0.startMillis < b && $0.endMillis > a }
                .map { "\($0.speaker): \($0.text)" }
                .joined(separator: "\n")
            let touchesLast = out.last?.endMillis == a
            if text.isEmpty {
                if touchesLast, b - a < minMillis { out[out.count - 1].endMillis = b }
            } else if touchesLast, out.last?.text == text || b - a < minMillis {
                out[out.count - 1].endMillis = b
            } else if touchesLast, let last = out.last, last.endMillis - last.startMillis < minMillis {
                out[out.count - 1] = SubtitleCue(startMillis: last.startMillis, endMillis: b, text: text)
            } else {
                out.append(SubtitleCue(startMillis: a, endMillis: b, text: text))
            }
        }
        for i in out.indices where out[i].endMillis - out[i].startMillis < minMillis {
            let next = i + 1 < out.count ? out[i + 1].startMillis : Int.max
            out[i].endMillis = min(out[i].startMillis + minMillis, next)
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter SubtitlesTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Transcribe/Subtitles.swift Tests/DabberCoreTests/SubtitlesTests.swift
git commit -m "feat: build non-overlapping subtitle cues with speakers and a 300 ms minimum"
```

---

### Task 3: Subtitle track in the slides video

**Files:**
- Create: `Sources/DabberCore/Finalize/SubtitleTrack.swift`
- Modify: `Sources/DabberCore/Finalize/ChapterWriter.swift` (the private `sample` and `textFormat` functions)
- Modify: `Sources/DabberCore/Finalize/SlideshowWriter.swift:31-62`
- Test: `Tests/DabberCoreTests/FinalizerTests.swift` (next to `slideshowIsHEVCWithTheSameAudioChaptersAndTitle`)

- [ ] **Step 1: Write the failing test**

Add to the `FinalizerTests` extension that holds the slideshow tests:

```swift
    private func subtitleSamples(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var out: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            let data = try sample.dataBuffer!.dataBytes()
            let text = String(decoding: data.dropFirst(2), as: UTF8.self)
            out.append(String(format: "%.3f+%.3f ", sample.presentationTimeStamp.seconds, sample.duration.seconds) + text)
        }
        return out
    }

    @Test func slideshowCarriesRussianSubtitlesThatAreOffByDefault() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("mix.m4a")
        let writer = try AACWriter(url: audio, channels: 2)
        try writer.write(sine(frames: 144_000, channels: 2))
        try writer.closeAndVerify()
        let slides = [try slide(dir, atSeconds: 0, screen())]
        let out = dir.appendingPathComponent("mix.mp4")
        try SlideshowWriter.write(
            audio: audio, slides: slides, chapters: [Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_500, title: "Mark 1")],
            subtitles: [SubtitleCue(startMillis: 500, endMillis: 1_000, text: "Я: Привет"),
                        SubtitleCue(startMillis: 1_100, endMillis: 2_000, text: "Собеседники: Да")],
            title: nil, to: out)
        let asset = AVURLAsset(url: out)
        let group = try #require(try await asset.loadMediaSelectionGroup(for: .legible))
        #expect(group.options.contains { $0.extendedLanguageTag == "ru" })
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        #expect(try await track.load(.isEnabled) == false)
        #expect(try await subtitleSamples(out) == [
            "0.000+0.500 ", "0.500+0.600 Я: Привет", "1.100+0.900 Собеседники: Да", "2.000+1.000 ",
        ])
        #expect(try await chapterList(out) == ["0.000 Start", "1.500 Mark 1"])
    }

    @Test func aCueInTheLastMomentOfTheAudioIsDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("mix.m4a")
        let writer = try AACWriter(url: audio, channels: 2)
        try writer.write(sine(frames: 144_000, channels: 2))
        try writer.closeAndVerify()
        let out = dir.appendingPathComponent("mix.mp4")
        try SlideshowWriter.write(
            audio: audio, slides: [try slide(dir, atSeconds: 0, screen())], chapters: [],
            subtitles: [SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Раз"),
                        SubtitleCue(startMillis: 2_950, endMillis: 3_250, text: "Я: Да")],
            title: nil, to: out)
        #expect(try await subtitleSamples(out) == ["0.000+1.000 ", "1.000+1.000 Я: Раз", "2.000+1.000 "])
        try SlideshowWriter.write(
            audio: audio, slides: [try slide(dir, atSeconds: 0, screen())], chapters: [],
            subtitles: [SubtitleCue(startMillis: 2_950, endMillis: 3_250, text: "Я: Да")], title: nil, to: out)
        #expect(try await AVURLAsset(url: out).loadTracks(withMediaType: .subtitle).isEmpty)
    }
```

Why these samples: the 0–0.5 s gap is long enough for an empty sample. The 100 ms gap between 1.0 and 1.1 s is shorter than `Subtitles.minMillis`, so the lane stretches the previous sample over it: «Я: Привет» runs 0.5–1.1 s. The final empty sample covers 2.0–3.0 s because the audio is 3 s long.

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter FinalizerTests/slideshowCarriesRussianSubtitlesThatAreOffByDefault`
Expected: build error, `extra argument 'subtitles' in call`.

- [ ] **Step 3: Share the tx3g sample and format code**

In `Sources/DabberCore/Finalize/ChapterWriter.swift`:
- change `private static func sample(_ title: String, start: CMTime, duration: CMTime, format: CMFormatDescription)` to `static func sample(...)` (internal);
- change `private static func textFormat() throws -> CMFormatDescription` to `static func textFormat(mediaType: CMMediaType = kCMMediaType_Text, subType: FourCharCode = kCMTextFormatType_3GText) throws -> CMFormatDescription` and pass `mediaType: mediaType, mediaSubType: subType` to `CMFormatDescriptionCreate`. The chapter lane keeps calling `textFormat()` and keeps its exact bytes.

- [ ] **Step 4: Write the subtitle lane**

`Sources/DabberCore/Finalize/SubtitleTrack.swift`:

```swift
import AVFoundation
import CoreMedia

enum SubtitleTrack {
    /// A disabled (off by default) Russian tx3g subtitle track. Gaps get empty samples so a cue never outlives its
    /// speech; a gap shorter than Subtitles.minMillis is given to the previous sample instead.
    static func lane(_ cues: [SubtitleCue], end: CMTime, writer: AVAssetWriter) throws -> WriterFeed.Lane? {
        let spans = spans(cues, endMillis: Int(end.seconds * 1000))
        guard spans.contains(where: { !$0.text.isEmpty }) else { return nil }
        let format = try ChapterWriter.textFormat(mediaType: kCMMediaType_Subtitle, subType: kCMSubtitleFormatType_3GText)
        var samples = try spans.map { span in
            try ChapterWriter.sample(
                span.text, start: CMTime(value: CMTimeValue(span.start), timescale: 1000),
                duration: CMTime(value: CMTimeValue(span.end - span.start), timescale: 1000), format: format)
        }
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        input.languageCode = "rus"
        input.extendedLanguageTag = "ru"
        input.marksOutputTrackAsEnabled = false
        writer.add(input)
        return (input, { samples.isEmpty ? nil : samples.removeFirst() })
    }

    /// Contiguous samples from 0 to the end of the audio: cues plus empty gaps, none shorter than Subtitles.minMillis.
    static func spans(_ cues: [SubtitleCue], endMillis: Int) -> [(start: Int, end: Int, text: String)] {
        var spans: [(start: Int, end: Int, text: String)] = []
        // A cue starting in the last minMillis of the audio would be cut below minMillis; it is dropped.
        for cue in cues where cue.startMillis <= endMillis - Subtitles.minMillis {
            let t = spans.last?.end ?? 0
            if cue.startMillis - t >= Subtitles.minMillis {
                spans.append((t, cue.startMillis, ""))
            } else if !spans.isEmpty {
                spans[spans.count - 1].end = cue.startMillis
            }
            spans.append((spans.last?.end ?? cue.startMillis, min(cue.endMillis, endMillis), cue.text))
        }
        if let t = spans.last?.end, endMillis - t >= Subtitles.minMillis { spans.append((t, endMillis, "")) }
        return spans
    }
}
```

If the first cue starts less than `minMillis` after 0, the first span starts at the cue's own start (no leading empty sample); the writer shows nothing before the first sample.

- [ ] **Step 5: Add the lane to the slideshow**

In `Sources/DabberCore/Finalize/SlideshowWriter.swift` change the signature on line 31 to

```swift
    public static func write(
        audio: URL, slides: [Slide], chapters: [Chapter], subtitles: [SubtitleCue] = [], title: String?, to out: URL
    ) throws {
```

After the `let text = try ChapterWriter.chapterLane(...)` line add

```swift
        let captions = try SubtitleTrack.lane(subtitles, end: end, writer: writer)
```

and replace the `WriterFeed(...)` line with

```swift
        try WriterFeed([pictures, source.lane(sound)] + [text, captions].compactMap { $0 }).run(writer)
```

- [ ] **Step 6: Run the slideshow tests**

Run: `scripts/test.sh --filter FinalizerTests/slideshow`
Expected: the new test and `slideshowIsHEVCWithTheSameAudioChaptersAndTitle`, `slideshowWithoutUsableFramesFails` pass. If the sample list differs only in the first or last empty sample, re-check the lane rules above against the test, do not loosen the test.

- [ ] **Step 7: Commit**

```bash
git add Sources/DabberCore/Finalize/SubtitleTrack.swift Sources/DabberCore/Finalize/ChapterWriter.swift Sources/DabberCore/Finalize/SlideshowWriter.swift Tests/DabberCoreTests/FinalizerTests.swift
git commit -m "feat: slides video carries a Russian subtitle track that is off by default"
```

---

### Task 4: Transcription step in the finalizer

**Files:**
- Modify: `Sources/DabberCore/Model/SessionManifest.swift:73-91` (`FinalizeReport`)
- Modify: `Sources/DabberCore/Finalize/Finalizer.swift`
- Modify: `Sources/DabberCore/Finalize/Delivery.swift` (`finishAndDeliver`, `recover`)
- Modify: `Sources/DabberCore/App/RecorderModel.swift` (`problems`)
- Test: `Tests/DabberCoreTests/FinalizerTests.swift`, `Tests/DabberCoreTests/RecorderModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `FinalizerTests` (uses the file's `makeSession()`: a mono mic «A» with audio and a stereo computer track):

```swift
    private final class Asked: @unchecked Sendable {
        var names: [String] = []
    }

    @Test func finalizerTranscribesEachTrackWithItsSpeaker() throws {
        let dir = try makeSession()
        let asked = Asked()
        let report = try Finalizer.run(dir, speech: { url in
            asked.names.append(url.lastPathComponent)
            return url.lastPathComponent.hasPrefix("mic")
                ? [SpokenWord(startMillis: 1_000, endMillis: 1_400, text: "Привет")]
                : [SpokenWord(startMillis: 100, endMillis: 600, text: "Начнём")]
        })
        #expect(asked.names.sorted() == ["computer audio.m4a", "mic - A.m4a"])
        #expect(report.transcriptError == nil)
        let text = try String(contentsOf: dir.appendingPathComponent(Transcript.textFile), encoding: .utf8)
        #expect(text == "[00:00:00] Собеседники: Начнём\n[00:00:01] Я: Привет\n")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.srtFile).path))
    }

    @Test func aTranscriptionFailureKeepsTheRecordingAndIsReported() throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "no model" } }
        let dir = try makeSession()
        let report = try Finalizer.run(dir, speech: { _ in throw Boom() })
        #expect(report.transcriptError == "no model")
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mix.m4a")).length == 144_000)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
    }

    @Test func withoutSpeechNothingIsTranscribed() throws {
        let dir = try makeSession()
        let report = try Finalizer.run(dir)
        #expect(report.transcriptError == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
    }
```

`Asked` is a plain class, not a `Mutex`: an escaping closure cannot capture a noncopyable `Mutex`, and `Finalizer` calls `speech` one track at a time.

At the end of `Tests/DabberCoreTests/RecorderModelTests.swift` add a free test function, like the others in that file:

```swift
@MainActor @Test func aTranscriptFailureIsAProblem() {
    let report = FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], transcriptError: "no model")
    #expect(RecorderModel.problems(report) == ["Transcript failed: no model"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter FinalizerTests/transcri`
Expected: build error, `extra argument 'speech' in call`.

- [ ] **Step 3: Add `transcriptError` to the report**

In `FinalizeReport` (`Sources/DabberCore/Model/SessionManifest.swift`) add the stored property `public var transcriptError: String?` after `unreadable`, add the init parameter `transcriptError: String? = nil` after `unreadable: [String]? = nil`, and assign it. Old `session.json` files without the key still decode because the property is optional.

- [ ] **Step 4: Add the step to `Finalizer`**

In `Sources/DabberCore/Finalize/Finalizer.swift`:

1. Add `let speaker: String` to the private `Track` struct and set it where tracks are built (line 47):

```swift
            tracks.append(Track(
                base: source.trackBase, channels: source.channels, backup: source.backup == true,
                speaker: source.kind == .mic ? Transcript.me : Transcript.others,
                reader: TimelineReader(placements: placements, sources: sources, channels: source.channels),
                plans: plans))
```

2. Change the signature of `run` to `public static func run(_ dir: URL, speech: SpeechToText? = nil) throws -> FinalizeReport`.

3. Right after `try mix.closeAndVerify()` add

```swift
        var cues: [SubtitleCue] = []
        var transcriptError: String?
        if total > 0, let speech {
            do {
                let lines = try transcribe(tracks, dir: dir, speech: speech)
                if !lines.isEmpty {
                    try Transcript.text(lines, marks: manifest.marks)
                        .write(to: dir.appendingPathComponent(Transcript.textFile), atomically: true, encoding: .utf8)
                    try Transcript.srt(lines)
                        .write(to: dir.appendingPathComponent(Transcript.srtFile), atomically: true, encoding: .utf8)
                    cues = Subtitles.cues(lines)
                }
            } catch {
                transcriptError = "\(error)"
            }
        }
```

4. Pass the cues to the slideshow: `slidesError = slideshow(manifest, dir: dir, chapters: chapters, subtitles: cues)`, add the `subtitles: [SubtitleCue]` parameter to the private `slideshow` function and pass `subtitles: subtitles` to `SlideshowWriter.write`.

5. Add `transcriptError: transcriptError` to the `FinalizeReport(...)` call.

6. Add the helper below `slideshow`:

```swift
    private static func transcribe(_ tracks: [Track], dir: URL, speech: SpeechToText) throws -> [TranscriptLine] {
        let heard = tracks.filter { !$0.reader.placements.isEmpty }
        return Transcript.merge(try heard.map { track in
            Transcript.lines(try speech(dir.appendingPathComponent(track.base + ".m4a")), speaker: track.speaker)
        })
    }
```

7. Thread `speech` through: `finish(_ dir: URL, speech: SpeechToText? = nil)` calls `run(dir, speech: speech)`; `recoverAll(dirs:speech:onError:onReport:)` gets `speech: SpeechToText? = nil` before `onError` and calls `run(dir, speech: speech)`.

- [ ] **Step 5: Thread `speech` through `Delivery`**

In `Sources/DabberCore/Finalize/Delivery.swift`: `finishAndDeliver(_ dir: URL, output: URL, mover: Mover = .live, speech: SpeechToText? = nil)` calls `Finalizer.finish(dir, speech: speech)`; `recover(_:work:output:mover:speech:onError:onReport:)` gets `speech: SpeechToText? = nil` after `mover` and calls `Finalizer.recoverAll(dirs: dirs, speech: speech, onError: onError, onReport: onReport)`.

- [ ] **Step 6: Show the failure in the menu**

In `RecorderModel.problems` (`Sources/DabberCore/App/RecorderModel.swift:355`) append

```swift
            + (report.transcriptError.map { ["Transcript failed: \($0)"] } ?? [])
```

- [ ] **Step 7: Run the tests**

Run: `scripts/test.sh --filter FinalizerTests` and then `scripts/test.sh --filter RecorderModelTests`
Expected: all pass, including the existing finalizer tests (the file list in `finalizerRendersTracksMixAndReportThenDeletesCAFs` is unchanged because no `speech` is passed).

- [ ] **Step 8: Commit**

```bash
git add Sources/DabberCore Tests/DabberCoreTests
git commit -m "feat: finalizer transcribes each track into transcript files and video subtitles, failures are reported"
```

---

### Task 5: FluidAudio adapter target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/DabberSpeech/ParakeetSpeech.swift`
- Test: `Tests/DabberSpeechTests/ParakeetSpeechTests.swift`

- [ ] **Step 1: Add the dependency and targets**

Replace `Package.swift` with

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dabber",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .target(name: "DabberCore"),
        .target(name: "DabberSpeech", dependencies: ["DabberCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "Dabber", dependencies: ["DabberCore", "DabberSpeech"]),
        .testTarget(name: "DabberCoreTests", dependencies: ["DabberCore"]),
        .testTarget(name: "DabberSpeechTests", dependencies: ["DabberSpeech"]),
    ]
)
```

The first resolve downloads FluidAudio and its binary `NemoTextProcessing.xcframework` (87 MB). Commit the generated `Package.resolved`.

- [ ] **Step 2: Write the failing test**

`Tests/DabberSpeechTests/ParakeetSpeechTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/test.sh --filter ParakeetSpeechTests`
Expected: build error, `cannot find 'ParakeetSpeech' in scope`.

- [ ] **Step 4: Write the adapter**

`Sources/DabberSpeech/ParakeetSpeech.swift`:

```swift
import DabberCore
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 on the Neural Engine. The model (about 470 MB) is downloaded on first use into FluidAudio's
/// cache in Application Support and stays loaded for the life of the app. No language hint: with one, English terms
/// in Russian speech come out in Cyrillic.
public final class ParakeetSpeech: @unchecked Sendable {
    public static let shared = ParakeetSpeech()

    private let lock = NSLock()
    private var manager: AsrManager?

    public func transcribe(_ url: URL) throws -> [SpokenWord] {
        try lock.withLock { try blocking { try await self.run(url) } }
    }

    private func run(_ url: URL) async throws -> [SpokenWord] {
        let asr = try await loaded()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &state)
        return Self.words(result.tokenTimings ?? [])
    }

    private func loaded() async throws -> AsrManager {
        if let manager { return manager }
        let version = AsrModelVersion.v3
        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(models)
        manager = asr
        return asr
    }

    static func words(_ tokens: [TokenTiming]) -> [SpokenWord] {
        var out: [SpokenWord] = []
        for token in tokens {
            let text = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = Int((token.startTime * 1000).rounded()), end = Int((token.endTime * 1000).rounded())
            if let last = out.last, !token.token.hasPrefix(" "), !token.token.hasPrefix("\n") {
                out[out.count - 1] = SpokenWord(startMillis: last.startMillis, endMillis: end, text: last.text + text)
            } else if !text.isEmpty {
                out.append(SpokenWord(startMillis: start, endMillis: end, text: text))
            }
        }
        return out
    }
}

/// Finalizer is synchronous and runs on a background queue; this waits there for the async FluidAudio call.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, any Error>?
    Task.detached(priority: .utility) {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}
```

`TdtConfig(blankId:)` and `ASRConfig(tdtConfig:encoderHiddenSize:)` are the calls FluidAudio's own CLI makes (`Sources/FluidAudioCLI/Commands/ASR/Parakeet/SlidingWindow/TranscribeCommand.swift` in FluidAudio 0.17.5). If the compiler rejects one of them, open that file in `.build/checkouts/FluidAudio` and copy the call from `runBatch`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/test.sh --filter ParakeetSpeechTests`
Expected: both tests pass. The first build compiles FluidAudio and takes a few minutes; run it with `nice -n 10` if the Mac is busy.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/DabberSpeech Tests/DabberSpeechTests
git commit -m "feat: Parakeet v3 speech-to-text through FluidAudio as a separate target"
```

---

### Task 6: Wire speech into the app and the headless mode

**Files:**
- Modify: `Sources/Dabber/AppDelegate.swift:13-30` (the `RecorderModel(...)` call) and `:62-68` (`Delivery.recover`)
- Modify: `Sources/Dabber/Headless.swift:277` and the `dispatch` switch

- [ ] **Step 1: App**

Add `import DabberSpeech` to `Sources/Dabber/AppDelegate.swift`. In the `RecorderModel(...)` call add, after `persistNames:`,

```swift
        finalize: { try Delivery.finishAndDeliver($0, output: $1, speech: ParakeetSpeech.shared.transcribe) },
```

and in the launch recovery pass `speech: ParakeetSpeech.shared.transcribe` to `Delivery.recover(...)` after `output: output`.

- [ ] **Step 2: Headless**

Add `import DabberSpeech` to `Sources/Dabber/Headless.swift`. Replace lines 277-279 with

```swift
            let report = try Finalizer.run(stopped, speech: ParakeetSpeech.shared.transcribe)
            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)"
                + (report.slidesError.map { " slidesError=\($0)" } ?? "")
                + (report.transcriptError.map { " transcriptError=\($0)" } ?? ""))
```

Add a case to `dispatch`, before `default:`, for manual checks:

```swift
        case "--transcribe":
            guard args.count == 2 else { return 64 }
            let words = try ParakeetSpeech.shared.transcribe(URL(fileURLWithPath: args[1]))
            for line in Transcript.lines(words, speaker: Transcript.me) {
                log.line("\(line.startMillis)\t\(line.endMillis)\t\(line.text)")
            }
            return 0
```

- [ ] **Step 3: Build and try it on a real file**

```bash
scripts/build-app.sh
```

Then transcribe one track of an existing recording (the first run downloads the model, about two minutes):

```bash
nice -n 10 .build/release/Dabber --transcribe "$HOME/Library/Mobile Documents/com~apple~CloudDocs/dabber/2026-10-01 13-01 дальше в edenex/mic - Semyon’s AirPods.m4a"
```

Expected: timed Russian lines on stdout, `EXIT 0` (`scripts/build-app.sh` builds `.build/release/Dabber`). Then note where the model landed: `ls ~/Library/Application\ Support/FluidAudio/Models`. Task 8 Step 3 needs this path.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dabber
git commit -m "feat: the app and headless mode transcribe finished recordings with Parakeet"
```

---

### Task 7: Docs and credits

**Files:**
- Modify: `README.md`, `README.ru.md` (feature list at the top, a new `### Transcript and subtitles` / `### Расшифровка и субтитры` section after `### Slides` / «Слайды», and `## License and credits`)
- Modify: `docs/backlog.md:3`

- [ ] **Step 1: README sections**

English text (put the Russian translation in `README.ru.md` in the same places, following the style of the neighbouring Russian sections):

```markdown
### Transcript and subtitles

After Stop, Dabber transcribes the recording on your Mac with the Parakeet speech model. Nothing is sent anywhere.
Each source is transcribed on its own: microphones are labelled «Я», Mac audio «Собеседники».

- `transcript.txt`: the text with times and your marks.
- `transcript.srt`: subtitles for any player.
- In the slides video, a Russian subtitle track. It is off when the video opens: turn it on in QuickTime Player
  with View > Subtitles.

The first transcription downloads the model (about 470 MB) and prepares it, which takes about two minutes and needs
the internet. After that a one-hour meeting takes well under a minute. If transcription fails, the recording is
delivered without a transcript and the menu says why.
```

Add to the feature list at the top: `- **Transcript** (on your Mac): text and subtitles for every recording, with «Я» and «Собеседники».`

In `## License and credits` add: speech recognition uses FluidAudio (Apache-2.0) and NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

- [ ] **Step 2: Backlog**

Replace the Whisper entry in `docs/backlog.md` with: `- **Transcript**: done on 2026-10-04 with Parakeet v3 through FluidAudio (see docs/superpowers/plans/2026-10-04-dabber-parakeet-subtitles.md). Open ideas: split «Собеседники» by voice with FluidAudio diarization; drop mic text that is the other side heard through the speakers.`

- [ ] **Step 3: Commit**

```bash
git add README.md README.ru.md docs/backlog.md
git commit -m "docs: transcript and subtitles, model credits"
```

---

### Task 8: Full check

- [ ] **Step 1: Full test suite, once**

Run: `nice -n 10 scripts/test.sh`
Expected: all tests pass.

- [ ] **Step 2: Install and record**

```bash
scripts/install-app.sh
```

Record about a minute with slides on, Mac audio playing someone speaking Russian and you answering into the mic, one Mark in the middle. Stop.

Expected in the delivered folder: `transcript.txt` with «Собеседники» and «Я» lines and the mark, `transcript.srt`, and the `.mp4`. Open the `.mp4` in QuickTime Player: no subtitles at first; View > Subtitles > Russian shows them; text disappears in pauses; chapters still work.

- [ ] **Step 3: Failure path**

Turn Wi-Fi off, delete the model folder (`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml` or wherever Task 6 Step 3 put it; check with `ls ~/Library/Application\ Support/FluidAudio/Models`), record 10 seconds, Stop. Expected: the recording is delivered, the menu shows `Transcript failed: …`. Turn Wi-Fi back on.

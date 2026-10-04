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
    static let minSentenceMillis = 1_000

    public static func lines(_ words: [SpokenWord], speaker: String) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        for w in words {
            let word = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if let c = current, w.startMillis - c.endMillis < pauseMillis, c.text.count + 1 + word.count <= maxChars {
                current = TranscriptLine(startMillis: c.startMillis, endMillis: max(c.endMillis, w.endMillis), speaker: speaker, text: c.text + " " + word)
            } else {
                if let c = current { out.append(c) }
                current = TranscriptLine(startMillis: w.startMillis, endMillis: max(w.endMillis, w.startMillis + 1), speaker: speaker, text: word)
            }
            if let c = current, c.endMillis - c.startMillis >= minSentenceMillis, let last = word.last, ".?!".contains(last) {
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

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

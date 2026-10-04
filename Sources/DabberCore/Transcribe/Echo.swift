import Foundation

extension Transcript {
    static let echoWindowMillis = 1_500
    static let echoMinRun = 2

    /// Without headphones the microphone also hears Mac audio, so the same speech would appear as «Я» too.
    /// A mic word is echo when Mac audio has the same word within 1.5 s of its start and at least two such mic
    /// words follow one another. A lone match, like a «да» that happens to coincide, is kept.
    static func withoutEcho(_ mic: [SpokenWord], heard: [SpokenWord]) -> [SpokenWord] {
        var starts: [String: [Int]] = [:]
        for word in heard {
            let key = echoKey(word.text)
            if !key.isEmpty { starts[key, default: []].append(word.startMillis) }
        }
        let match = mic.map { word in
            starts[echoKey(word.text)]?.contains { abs($0 - word.startMillis) <= echoWindowMillis } ?? false
        }
        var kept: [SpokenWord] = []
        var i = 0
        while i < mic.count {
            var end = i + 1
            if match[i] {
                while end < mic.count, match[end] { end += 1 }
                if end - i >= echoMinRun {
                    i = end
                    continue
                }
            }
            kept += mic[i..<end]
            i = end
        }
        return kept
    }

    static func echoKey(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber })
    }
}

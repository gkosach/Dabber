import AVFoundation
import CoreMedia

enum SubtitleTrack {
    /// A disabled (off by default) Russian tx3g subtitle track. Gaps get empty samples so a cue never outlives its
    /// speech; a gap shorter than Subtitles.minMillis is given to the previous sample instead.
    static func lane(_ cues: [SubtitleCue], end: CMTime, writer: AVAssetWriter) throws -> WriterFeed.Lane? {
        let spans = spans(cues, endMillis: Int(end.seconds * 1000))
        guard spans.contains(where: { !$0.text.isEmpty }) else { return nil }
        let format = try TextSamples.format(mediaType: kCMMediaType_Subtitle, subType: kCMSubtitleFormatType_3GText)
        var samples = try spans.map { span in
            try TextSamples.sample(
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

    /// Contiguous samples from 0: cues plus empty gaps, none shorter than Subtitles.minMillis. The last one may end up to minMillis before the audio does.
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
            spans.append((spans.last?.end ?? 0, min(cue.endMillis, endMillis), cue.text))
        }
        if let t = spans.last?.end, endMillis - t >= Subtitles.minMillis { spans.append((t, endMillis, "")) }
        return spans
    }
}

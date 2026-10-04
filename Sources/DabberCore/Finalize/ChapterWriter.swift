import AVFoundation
import CoreMedia

public enum ChapterError: Error, CustomStringConvertible {
    case noAudio(String)
    case write(String, String)

    public var description: String {
        switch self {
        case .noAudio(let file): return "\(file): no audio to add chapters to"
        case .write(let file, let why): return "\(file): writing chapters failed: \(why)"
        }
    }
}

public enum ChapterWriter {
    public static func write(_ chapters: [Chapter], title: String? = nil, into url: URL) throws {
        let name = url.lastPathComponent
        let frames = try AVAudioFile(forReading: url).length
        let source = try AudioPassthrough(url)
        let temp = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        writer.metadata = titleMetadata(title)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
        writer.add(audio)
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        let text = try chapterLane(chapters, end: end, writer: writer, linkedFrom: [audio])
        guard writer.startWriting() else { throw ChapterError.write(name, writer.error.map(WriterFailure.text) ?? "start") }
        writer.startSession(atSourceTime: .zero)
        try WriterFeed([source.lane(audio)] + (text.map { [$0] } ?? [])).run(writer)
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, source.reader.status == .completed else {
            throw ChapterError.write(name, (writer.error ?? source.reader.error).map(WriterFailure.text) ?? "no reason given")
        }
        let written = try AVAudioFile(forReading: out).length
        guard written == frames else {
            throw FinalizeError.lengthMismatch(file: name, expected: Int(frames), actual: Int(written))
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
    }

    static func titleMetadata(_ title: String?) -> [AVMetadataItem] {
        guard let title else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        return [item]
    }

    static func chapterLane(
        _ chapters: [Chapter], end: CMTime, writer: AVAssetWriter, linkedFrom tracks: [AVAssetWriterInput]
    ) throws -> WriterFeed.Lane? {
        guard !chapters.isEmpty else { return nil }
        let format = try TextSamples.format()
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
        input.marksOutputTrackAsEnabled = false
        writer.add(input)
        for track in tracks {
            track.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        }
        var samples = try chapters.indices.map { i in
            let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
            let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
            return try TextSamples.sample(chapters[i].title, start: start, duration: next - start, format: format)
        }
        return (input, { samples.isEmpty ? nil : samples.removeFirst() })
    }
}

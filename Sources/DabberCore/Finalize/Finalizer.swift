import Foundation
import Synchronization

public enum Finalizer {
    public static let chunkFrames = 48_000
    public static let mixFile = "mix.m4a"
    public static let videoFile = "mix.mp4"
    /// Lives in the session folder while speech runs and holds the attempt number. If it is still there on the next
    /// run, that attempt never finished: a crash in speech, a kill or a power loss. One such attempt is tried again;
    /// after two, transcription is not attempted, so a model that crashes costs at most two launches.
    static let transcribingMarker = "transcribing"
    static let maxUnfinished = 2

    private struct Track {
        let base: String
        let channels: Int
        let backup: Bool
        let speaker: String
        let reader: TimelineReader
        let plans: [FinalizePlan]
    }

    @discardableResult
    public static func run(_ dir: URL, speech: SpeechToText? = nil) throws -> FinalizeReport {
        var manifest = try SessionManifest.load(from: dir)
        let marker = dir.appendingPathComponent(transcribingMarker)
        let unfinished = max(0, (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int($0) } ?? 0)
        try? FileManager.default.removeItem(at: marker)
        var tracks: [Track] = []
        var rendered: [String] = []
        var unreadable: [String] = []
        var cafs: [CAFSegment] = []
        for source in manifest.sources {
            var present: [SegmentRecord] = []
            var files: [CAFSegment] = []
            for record in source.segments {
                let url = dir.appendingPathComponent(record.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let caf = try? CAFSegment(url: url) else {
                    unreadable.append(record.file)
                    continue
                }
                present.append(record)
                files.append(caf)
            }
            cafs += files
            let plans = FinalizePlan.make(present, fileFrames: files.map(\.frames))
            let planned = Set(plans.map(\.file))
            rendered += plans.map(\.file)
            let sources: [any SegmentSource] = zip(present, files).compactMap { record, caf in
                guard planned.contains(record.file) else { return nil }
                let plan = plans.first { $0.file == record.file }!
                return plan.resample ? DriftResampler(caf, targetFrames: plan.segment.frames) : caf
            }
            let placements = Timeline.place(plans.map(\.segment), sessionStartNanos: manifest.sessionStartNanos)
            tracks.append(Track(
                base: source.trackBase, channels: source.channels, backup: source.backup == true,
                speaker: source.kind == .mic ? Transcript.me : Transcript.others,
                reader: TimelineReader(placements: placements, sources: sources, channels: source.channels),
                plans: plans))
        }
        let total = tracks.map(\.reader.totalFrames).max() ?? 0
        var slidesError: String?
        let writers = try tracks.map { try AACWriter(url: dir.appendingPathComponent($0.base + ".m4a"), channels: $0.channels) }
        let mix = try AACWriter(url: dir.appendingPathComponent(mixFile), channels: 2)
        var start = 0
        while start < total {
            let range = start..<min(start + chunkFrames, total)
            let pcms = try tracks.map { try $0.reader.read(range) }
            let contributing = zip(tracks, pcms).filter { !$0.0.reader.placements.isEmpty }
            let mono = contributing.filter { $0.0.channels == 1 && !$0.0.backup }.map(\.1)
            let stereo = contributing.filter { $0.0.channels != 1 }.map(\.1)
            let backup = contributing.filter { $0.0.channels == 1 && $0.0.backup }.map(\.1)
            try encodeConcurrently(writers + [mix], pcms + [Mixer.mixToStereo(mono: mono, stereo: stereo, backup: backup)])
            start = range.upperBound
        }
        for writer in writers { try writer.closeAndVerify() }
        try mix.closeAndVerify()
        var cues: [SubtitleCue] = []
        var transcriptError: String?
        var subtitlesError: String?
        if total >= Timeline.rate, let speech {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Transcript.textFile))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Transcript.srtFile))
            if unfinished >= maxUnfinished {
                transcriptError = "not attempted: transcription did not finish twice"
            } else {
                do {
                    try String(unfinished + 1).write(to: marker, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: marker) }
                    let (lines, failure) = transcribe(tracks, dir: dir, speech: speech)
                    transcriptError = failure
                    if !lines.isEmpty {
                        try Transcript.text(lines, marks: manifest.marks)
                            .write(to: dir.appendingPathComponent(Transcript.textFile), atomically: true, encoding: .utf8)
                        try Transcript.srt(lines)
                            .write(to: dir.appendingPathComponent(Transcript.srtFile), atomically: true, encoding: .utf8)
                        cues = Subtitles.cues(lines)
                    }
                } catch {
                    transcriptError = brief(error)
                }
            }
        }
        if total > 0 {
            let millis = total * 1000 / Timeline.rate
            var chapters: [Chapter] = []
            if !manifest.marks.isEmpty {
                try Chapters.text(manifest.marks, durationMillis: millis)
                    .write(to: dir.appendingPathComponent(Chapters.textFile), atomically: true, encoding: .utf8)
                chapters = Chapters.make(manifest.marks, durationMillis: millis)
                for writer in writers { try ChapterWriter.write(chapters, into: writer.url) }
            }
            try ChapterWriter.write(chapters, title: manifest.name, into: mix.url)
            let video = slideshow(manifest, dir: dir, chapters: chapters, subtitles: cues)
            slidesError = video.slides
            subtitlesError = video.subtitles
        }
        unreadable += cafs.filter(\.damaged).map(\.url.lastPathComponent)
        var gaps: [GapRecord] = []
        var drift: [String: Double] = [:]
        var resampled: [String] = []
        for track in tracks {
            gaps += Timeline.gaps(track.reader.placements).map { GapRecord(track: track.base, atFrame: $0.atFrame, frames: $0.frames) }
            for plan in track.plans {
                drift[plan.file] = plan.driftMillis
                if plan.resample { resampled.append(plan.file) }
            }
        }
        let report = FinalizeReport(
            totalFrames: total, gaps: gaps, driftMillis: drift, resampled: resampled, slidesError: slidesError,
            unreadable: unreadable.isEmpty ? nil : unreadable,
            transcriptError: transcriptError, subtitlesError: subtitlesError)
        manifest.finalize = report
        try manifest.save(to: dir)
        for name in rendered where !unreadable.contains(name) {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(videoFile).path) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(SessionManifest.framesDir))
        }
        return report
    }

    static func slideshow(
        _ manifest: SessionManifest, dir: URL, chapters: [Chapter], subtitles: [SubtitleCue]
    ) -> (slides: String?, subtitles: String?) {
        let slides = manifest.frames
            .map { Slide(offsetNanos: $0.offsetNanos, url: dir.appendingPathComponent($0.file)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !slides.isEmpty else { return (nil, nil) }
        let out = dir.appendingPathComponent(videoFile)
        func attempt(_ cues: [SubtitleCue]) -> String? {
            do {
                try SlideshowWriter.write(
                    audio: dir.appendingPathComponent(mixFile), slides: slides, chapters: chapters, subtitles: cues,
                    title: manifest.name, to: out)
                return nil
            } catch {
                try? FileManager.default.removeItem(at: out)
                return brief(error)
            }
        }
        guard let failure = attempt(subtitles) else { return (nil, nil) }
        guard !subtitles.isEmpty else { return (failure, nil) }
        let retry = attempt([])
        return retry == nil ? (nil, failure) : (retry, nil)
    }

    static func brief(_ error: any Error) -> String {
        let text: String
        if let l = error as? LocalizedError, let d = l.errorDescription {
            text = d
        } else if type(of: error) is NSError.Type {
            text = error.localizedDescription
        } else {
            text = "\(error)"
        }
        return String(text.prefix(200))
    }

    /// A failed track does not cost the others their text. If every track failed the same way (the model is not
    /// ready, say), `failure` is that error once; otherwise it names each failed track. The 200 characters of
    /// error text are shared among the failed tracks, so every track name stays in the message.
    private static func transcribe(_ tracks: [Track], dir: URL, speech: SpeechToText) -> (lines: [TranscriptLine], failure: String?) {
        let heard = tracks.filter { !$0.reader.placements.isEmpty }
        var lines: [[TranscriptLine]] = []
        var failed: [(track: String, error: String)] = []
        for track in heard {
            do {
                lines.append(Transcript.lines(try speech(dir.appendingPathComponent(track.base + ".m4a")), speaker: track.speaker))
            } catch {
                failed.append((track.base, brief(error)))
            }
        }
        guard let first = failed.first else { return (Transcript.merge(lines), nil) }
        if failed.count == heard.count, failed.allSatisfy({ $0.error == first.error }) {
            return (Transcript.merge(lines), first.error)
        }
        let each = 200 / failed.count
        return (Transcript.merge(lines), failed.map { "\($0.track): \($0.error.prefix(each))" }.joined(separator: "; "))
    }

    public static func finish(_ dir: URL, speech: SpeechToText? = nil) throws -> URL {
        try run(dir, speech: speech)
        return try rename(dir)
    }

    public static func rename(_ dir: URL) throws -> URL {
        let name = try SessionManifest.load(from: dir).name
        try FileManager.default.moveItem(at: dir.appendingPathComponent(mixFile), to: dir.appendingPathComponent(name + ".m4a"))
        let video = dir.appendingPathComponent(videoFile)
        if FileManager.default.fileExists(atPath: video.path) {
            try FileManager.default.moveItem(at: video, to: dir.appendingPathComponent(name + ".mp4"))
        }
        let parent = dir.deletingLastPathComponent()
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(name) \(n)"
            if candidate == dir.lastPathComponent { return dir }
            let target = parent.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: dir, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }

    private static func encodeConcurrently(_ writers: [AACWriter], _ chunks: [[Float]]) throws {
        let errors = Mutex<[any Error]>([])
        DispatchQueue.concurrentPerform(iterations: writers.count) { i in
            do {
                try writers[i].write(chunks[i])
            } catch {
                errors.withLock { $0.append(error) }
            }
        }
        if let error = errors.withLock({ $0.first }) { throw error }
    }

    public static func needsRecovery(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let manifest = try? SessionManifest.load(from: dir), manifest.finalize == nil,
              let names = try? fm.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return names.contains { $0.hasSuffix(".caf") }
    }

    public static func sessionFolders(root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { root.appendingPathComponent($0) }
    }

    @discardableResult
    public static func recoverAll(
        dirs: [URL], speech: SpeechToText? = nil, onError: (URL, Error) -> Void = { _, _ in }, onReport: (URL, FinalizeReport) -> Void = { _, _ in }
    ) -> [URL] {
        var done: [URL] = []
        for dir in dirs where needsRecovery(dir) {
            do {
                let report = try run(dir, speech: speech)
                let named = try rename(dir)
                onReport(named, report)
                done.append(named)
            } catch {
                onError(dir, error)
            }
        }
        return done
    }
}

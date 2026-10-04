import AVFoundation
import DabberCore
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 on the Neural Engine. No language hint: with one, English terms in Russian speech come out
/// in Cyrillic. The model (about 470 MB, kept in FluidAudio's cache in Application Support) is downloaded and compiled
/// in the background by `prepare()`. `transcribe` never downloads: it runs inside finalize, which holds the delivery
/// lock and makes quitting wait, so until the model is ready it throws at once and the recording goes out without
/// a transcript.
public final class ParakeetSpeech: @unchecked Sendable {
    public static let shared = ParakeetSpeech()

    public enum SpeechError: LocalizedError {
        case notReady(String?)
        case downmix(String)

        public var errorDescription: String? {
            switch self {
            case .notReady(nil): "the speech model is not ready yet"
            case .notReady(let why?): "the speech model could not be loaded: \(why)"
            case .downmix(let name): "could not prepare \(name) for transcription"
            }
        }
    }

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loading = false
    private var loadError: String?
    private var failures = 0
    private static let maxFailures = 3

    /// Starts the download and load in the background. Calling it again is free; after a failure it retries,
    /// but gives up after three failures in one app run so a broken model is not downloaded again on every finalize.
    public func prepare() {
        let start = lock.withLock {
            guard manager == nil, !loading, failures < Self.maxFailures else { return false }
            loading = true
            loadError = nil
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) {
            do {
                let asr = try await Self.makeManager()
                self.lock.withLock { self.manager = asr; self.loadError = nil; self.loading = false }
            } catch {
                self.lock.withLock { self.loadError = error.localizedDescription; self.failures += 1; self.loading = false }
            }
        }
    }

    /// Blocks until the model is loaded. For the headless mode only.
    public func prepareNow() throws {
        if lock.withLock({ manager }) != nil { return }
        do {
            let asr = try blocking { try await Self.makeManager() }
            lock.withLock { manager = asr; loadError = nil }
        } catch {
            lock.withLock { loadError = error.localizedDescription; failures += 1 }
            throw error
        }
    }

    /// For launch recovery: a session recovered before the model is loaded would lose its transcript. Returns at once
    /// if the model is loaded or is not on disk (waiting would mean a download); otherwise starts the load and waits
    /// for it, at most `seconds`.
    public func waitIfCached(seconds: Double) async {
        if lock.withLock({ manager }) != nil { return }
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3) else { return }
        prepare()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (ready, busy) = lock.withLock { (manager != nil, loading) }
            if ready || !busy { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    public func transcribe(_ url: URL) throws -> [SpokenWord] {
        let (asr, failure) = lock.withLock { (manager, loadError) }
        guard let asr else {
            prepare()
            throw SpeechError.notReady(failure)
        }
        let mono = try Self.monoCopy(of: url)
        defer { if let mono { try? FileManager.default.removeItem(at: mono) } }
        return try blocking {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(mono ?? url, decoderState: &state)
            return Self.words(result.tokenTimings ?? [])
        }
    }

    private static func makeManager() async throws -> AsrManager {
        let version = AsrModelVersion.v3
        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(models)
        return asr
    }

    /// FluidAudio's `WordTiming` has no confidence, so the tokens are split into words by the same rule as
    /// `buildWordTimings` (a word-boundary token or an empty current word starts a new one). Each group goes through
    /// `buildWordTimings` for the text and times; its confidence is the mean of its token confidences.
    static func words(_ tokens: [TokenTiming]) -> [SpokenWord] {
        var groups: [[TokenTiming]] = []
        var currentText = ""
        for t in tokens {
            if t.token.isEmpty || t.token == "<blank>" || t.token == "<pad>" { continue }
            if isWordBoundary(t.token) || currentText.isEmpty {
                groups.append([t])
                currentText = stripWordBoundaryPrefix(t.token)
            } else {
                groups[groups.count - 1].append(t)
                currentText += t.token
            }
        }
        return groups.flatMap { group in
            let mean = group.map { Double($0.confidence) }.reduce(0, +) / Double(group.count)
            return buildWordTimings(from: group).compactMap { word -> SpokenWord? in
                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SpokenWord(
                    startMillis: Int((word.startTime * 1000).rounded()),
                    endMillis: Int((word.endTime * 1000).rounded()), text: text, confidence: mean)
            }
        }
    }

    /// FluidAudio reads only the left channel of a stereo file, so a multi-channel track is downmixed to a temporary
    /// mono 16 kHz copy first. Returns nil for a mono file.
    static func monoCopy(of url: URL) throws -> URL? {
        let input = try AVAudioFile(forReading: url)
        guard input.fileFormat.channelCount > 1 else { return nil }
        let fail = SpeechError.downmix(url.lastPathComponent)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let block: AVAudioFrameCount = 48_000 * 10
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 11)
        else { throw fail }
        converter.downmix = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dabber-mono-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var readError: Error?
            while true {
                var convError: NSError?
                let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                    inBuf.frameLength = 0
                    if input.framePosition < input.length {
                        do { try input.read(into: inBuf, frameCount: block) } catch { readError = error }
                    }
                    if readError != nil || inBuf.frameLength == 0 { inStatus.pointee = .endOfStream; return nil }
                    inStatus.pointee = .haveData
                    return inBuf
                }
                if let readError { throw readError }
                if status == .error { throw convError ?? fail }
                if outBuf.frameLength > 0 { try file.write(from: outBuf) }
                if status == .endOfStream { break }
            }
            file.close()
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}

/// Finalizer is synchronous and runs on a background queue; this waits there for the async FluidAudio call.
/// It blocks a thread of the shared pool while it waits; Delivery.lock lets only one transcription run at a time,
/// the same trade-off ChapterWriter.write already makes with its semaphore.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, any Error>?
    Task.detached(priority: Task.currentPriority) {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}

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

        public var errorDescription: String? {
            switch self {
            case .notReady(nil): "the speech model is still downloading"
            case .notReady(let why?): "the speech model could not be loaded: \(why)"
            }
        }
    }

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loading = false
    private var loadError: String?

    /// Starts the download and load in the background. Calling it again is free; after a failure it retries.
    public func prepare() {
        let start = lock.withLock {
            guard manager == nil, !loading else { return false }
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
                self.lock.withLock { self.loadError = error.localizedDescription; self.loading = false }
            }
        }
    }

    /// Blocks until the model is loaded. For the headless mode only.
    public func prepareNow() throws {
        if lock.withLock({ manager }) != nil { return }
        let asr = try blocking { try await Self.makeManager() }
        lock.withLock { manager = asr }
    }

    public func transcribe(_ url: URL) throws -> [SpokenWord] {
        let (asr, failure) = lock.withLock { (manager, loadError) }
        guard let asr else {
            prepare()
            throw SpeechError.notReady(failure)
        }
        return try blocking {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(url, decoderState: &state)
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
/// It blocks a thread of the shared pool while it waits; Delivery.lock lets only one transcription run at a time,
/// the same trade-off ChapterWriter.write already makes with its semaphore.
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

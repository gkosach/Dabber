import AVFoundation
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

    @Test func aMergedWordCarriesTheMeanTokenConfidence() {
        func c(_ token: String, _ start: Double, _ end: Double, _ conf: Float) -> TokenTiming {
            TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: conf)
        }
        let words = ParakeetSpeech.words([c(" При", 0.1, 0.2, 0.5), c("вет", 0.2, 0.4, 0.9), c(" да", 1.0, 1.2, 0.8)])
        #expect(words.map(\.text) == ["Привет", "да"])
        #expect(abs(words[0].confidence - 0.7) < 1e-6)
        #expect(abs(words[1].confidence - 0.8) < 1e-6)
    }

    @Test func aBareSpaceTokenConfidenceDoesNotLeakIntoTheNextWord() {
        let words = ParakeetSpeech.words([
            TokenTiming(token: " ", tokenId: 0, startTime: 0, endTime: 0.1, confidence: 0.1),
            TokenTiming(token: "5", tokenId: 0, startTime: 0.2, endTime: 0.3, confidence: 0.9),
            TokenTiming(token: "0", tokenId: 0, startTime: 0.3, endTime: 0.4, confidence: 0.9),
        ])
        #expect(words.map(\.text) == ["50"])
        #expect(abs(words[0].confidence - 0.9) < 1e-6)
    }

    @Test func noTokensNoWords() {
        #expect(ParakeetSpeech.words([]).isEmpty)
    }

    @Test func standaloneSpaceTokenSeparatesNumbers() {
        let words = ParakeetSpeech.words([
            t(" При", 0.0, 0.1), t("вет", 0.1, 0.3), t(" ", 0.3, 0.4), t("5", 0.5, 0.6), t("0", 0.6, 0.7), t(",", 0.7, 0.8),
        ])
        #expect(words.map(\.text) == ["Привет", "50,"])
    }

    @Test func stereoIsDownmixedToMono16k() throws {
        try checkDownmix(seconds: 1)
    }

    @Test func longStereoCrossesSeveralBlocks() throws {
        try checkDownmix(seconds: 25)
    }

    private func checkDownmix(seconds: Int) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dabber-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stereo.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * seconds))!
        buf.frameLength = AVAudioFrameCount(48_000 * seconds)
        for i in 0..<(48_000 * seconds) {
            buf.floatChannelData![0][i] = 0
            buf.floatChannelData![1][i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        }
        let mono = try #require(try ParakeetSpeech.monoCopy(of: url))
        defer { try? FileManager.default.removeItem(at: mono) }
        let out = try AVAudioFile(forReading: mono)
        #expect(out.fileFormat.channelCount == 1)
        #expect(out.fileFormat.sampleRate == 16_000)
        #expect(abs(Int(out.length) - 16_000 * seconds) < 200)
        let pcm = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(out.length))!
        try out.read(into: pcm)
        let n = Int(pcm.frameLength)
        let rms = (0..<n).reduce(Float(0)) { $0 + pcm.floatChannelData![0][$1] * pcm.floatChannelData![0][$1] } / Float(n)
        #expect(rms.squareRoot() > 0.1)
    }

    @Test func onlyNetworkFailuresCountAsNetwork() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(ParakeetSpeech.isNetwork(URLError(.timedOut)))
        #expect(ParakeetSpeech.isNetwork(offline))
        #expect(ParakeetSpeech.isNetwork(NSError(domain: "FluidAudio", code: 1, userInfo: [NSUnderlyingErrorKey: offline])))
        #expect(!ParakeetSpeech.isNetwork(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)))
        #expect(!ParakeetSpeech.isNetwork(ParakeetSpeech.SpeechError.notReady(nil)))
        // FluidAudio's own download errors count unless the model file is missing.
        let http = { (code: Int) in DownloadError.downloadFailed(path: "encoder", underlying: NSError(domain: "HTTP", code: code)) }
        for transient: DownloadError in [
            .stalled(path: "encoder", window: 30), .rateLimited(statusCode: 429, message: ""), http(503), http(429),
            .downloadFailed(path: "encoder", underlying: URLError(.networkConnectionLost)),
            .htmlErrorResponse(path: "tree", snippet: "<html>"), .invalidArtifact(path: "encoder", reason: "short"),
            .invalidResponse,
        ] {
            #expect(ParakeetSpeech.isNetwork(transient), "\(transient)")
        }
        for permanent: DownloadError in [
            .modelNotFound(path: "encoder"), .modelMissing(repo: "parakeet", missing: ["encoder"]),
            .networkDisabled(operation: "download"), http(404), http(403),
        ] {
            #expect(!ParakeetSpeech.isNetwork(permanent), "\(permanent)")
        }
    }
}

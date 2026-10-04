import AVFoundation

struct FeedTimedOut: Error, CustomStringConvertible {
    var description: String { "timed out" }
}

final class WriterFeed: @unchecked Sendable {
    typealias Lane = (input: AVAssetWriterInput, next: () throws -> CMSampleBuffer?)

    private let lanes: [Lane]
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure: (any Error)?

    init(_ lanes: [Lane]) {
        self.lanes = lanes
    }

    func run(_ writer: AVAssetWriter, timeout: TimeInterval = 600) throws {
        for i in lanes.indices {
            group.enter()
            lanes[i].input.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.feed.\(i)", qos: .utility)) { self.feed(i) }
        }
        let done = group.wait(timeout: .now() + timeout) == .success
        if let error = lock.withLock({ failure }) ?? (done ? nil : FeedTimedOut()) {
            writer.cancelWriting()
            throw error
        }
    }

    private func feed(_ i: Int) {
        let lane = lanes[i]
        while lane.input.isReadyForMoreMediaData {
            do {
                guard let next = try lane.next(), lane.input.append(next) else { return finish(lane.input) }
            } catch {
                lock.withLock { failure = failure ?? error }
                return finish(lane.input)
            }
        }
    }

    private func finish(_ input: AVAssetWriterInput) {
        input.markAsFinished()
        group.leave()
    }
}

/// An AVFoundation error prints as a dump of its user info. This keeps the readable part, the failure reason or else
/// the description, and adds the underlying OSStatus when the text does not show it yet:
/// "An unknown error occurred (-16364)".
enum WriterFailure {
    static func text(_ error: any Error) -> String {
        guard type(of: error) is NSError.Type else { return "\(error)" }
        let ns = error as NSError
        let text = ns.localizedFailureReason ?? ns.localizedDescription
        guard let code = status(error), !text.contains("(\(code))") else { return text }
        return "\(text) (\(code))"
    }

    /// The code of the underlying error, an OSStatus for AVFoundation errors.
    static func status(_ error: any Error) -> Int? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
    }
}

struct AudioPassthrough {
    let reader: AVAssetReader
    let format: CMFormatDescription
    let lane: (AVAssetWriterInput) -> WriterFeed.Lane

    init(_ url: URL) throws {
        let name = url.lastPathComponent
        let movie = AVMovie(url: url)
        guard let track = movie.tracks.first(where: { $0.mediaType == .audio }) else { throw ChapterError.noAudio(name) }
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer(), let format = first.formatDescription else {
            throw ChapterError.noAudio(name)
        }
        self.reader = reader
        self.format = format
        lane = { input in
            var pending: CMSampleBuffer? = first
            return (input, {
                if let buffer = pending {
                    pending = nil
                    return buffer
                }
                return output.copyNextSampleBuffer()
            })
        }
    }
}

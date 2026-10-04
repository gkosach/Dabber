import Foundation

/// A crash in CoreML or FluidAudio kills the whole app, so the only trace it leaves is work that started and never
/// finished. This keeps that count in UserDefaults across launches: a model load or a transcription adds one when it
/// starts and takes it back when it ends, with a result or an error. A finished transcription also clears what
/// earlier runs left, since it shows the model works; a finished load does not, because a model that loads fine can
/// still crash on every transcription. When the count is two at launch, speech stays off for that run. The count
/// starts over when the build changes: Dabber is reinstalled or macOS is updated.
final class SpeechBreaker: @unchecked Sendable {
    static let countKey = "speechUnfinished"
    static let buildKey = "speechUnfinishedBuild"
    static let limit = 2

    let tripped: Bool
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var carried: Int
    private var running = 0
    private var closed = false

    init(defaults: UserDefaults, build: String) {
        self.defaults = defaults
        if defaults.string(forKey: Self.buildKey) != build {
            defaults.set(build, forKey: Self.buildKey)
            defaults.set(0, forKey: Self.countKey)
        }
        carried = max(0, defaults.integer(forKey: Self.countKey))
        tripped = carried >= Self.limit
    }

    func begin() {
        lock.withLock {
            running += 1
            save()
        }
    }

    func end(clearing: Bool) {
        lock.withLock {
            running -= 1
            if clearing { carried = 0 }
            save()
        }
    }

    /// After this, work still running is not counted and nothing is saved any more.
    func quitting() {
        lock.withLock {
            running = 0
            save()
            closed = true
        }
    }

    /// Written through at once: the next thing may be a crash.
    private func save() {
        guard !closed else { return }
        defaults.set(carried + running, forKey: Self.countKey)
        defaults.synchronize()
    }
}

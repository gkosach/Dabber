/// What the speech model is doing, for the line under the Transcribe switch.
public enum SpeechModelStatus: Equatable, Sendable {
    /// No load was started in this app run.
    case idle
    /// The model files are being downloaded. The fraction of the download, when it is known.
    case downloading(Double?)
    /// The files are on disk and CoreML loads them. The first time it compiles them, which can take minutes.
    case preparing
    case ready
    /// The last load failed. `gaveUp`: the failure caps are reached, so no load is tried until the next launch.
    case failed(String, gaveUp: Bool)
}

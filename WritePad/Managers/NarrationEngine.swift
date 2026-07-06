import Foundation

/// An in-process text-to-speech engine. Implementations do their own threading,
/// so requirements are nonisolated and the engine is `Sendable`.
protocol NarrationEngine: Sendable {
    nonisolated func availableVoices() async -> [NarrationVoice]
    nonisolated func render(text: String, voice: NarrationVoice,
                            settings: NarrationSettings, to url: URL) async throws
    /// Blocks until any in-flight render finishes, so the process never tears
    /// down while MLX work is mid-flight.
    nonisolated func quiesce()
}

extension NarrationEngine {
    nonisolated func quiesce() {}
}

enum NarrationError: LocalizedError {
    case synthesis(String)
    case noVoiceSelected

    var errorDescription: String? {
        switch self {
        case .synthesis(let message): return message
        case .noVoiceSelected: return "Select a voice first."
        }
    }
}

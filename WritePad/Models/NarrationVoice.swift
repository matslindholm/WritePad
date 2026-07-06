/// A speaker offered by one of the in-process TTS engines.
struct NarrationVoice: Identifiable, Equatable, Sendable {
    enum Engine: Equatable, Sendable {
        case qwen3    // in-process swift-qwen3-tts (cloned German voices)
        case kokoro   // in-process swift-kokoro-tts (English)
    }

    let id: String
    let label: String
    let language: String
    let gender: String?
    let engine: Engine
}

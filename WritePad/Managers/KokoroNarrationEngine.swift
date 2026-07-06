import Foundation
import KokoroTTS

/// In-process Kokoro-TTS engine for the English voices. Loads the model once
/// (from the `mlx-community/Kokoro-82M-bf16` snapshot, downloading into the
/// sandbox cache on first use) and renders directly. Kokoro chunks phonemes
/// internally, so a whole pause-delimited block goes to `generate` in one call.
/// MLX corrupts its state under concurrent use, so every model touch runs on one
/// dedicated serial queue.
nonisolated final class KokoroNarrationEngine: NarrationEngine, @unchecked Sendable {
    private struct Voice {
        let id: String
        let label: String
        let gender: String
        /// Kokoro voice pack name; its prefix sets the accent (`a*` US, `b*` UK).
        let pack: String
    }

    // Curated by Kokoro's published quality grades; `af_heart` stays first so
    // English manuscripts auto-select it.
    private static let catalog = [
        Voice(id: "kokoro_heart", label: "Heart", gender: "female", pack: "af_heart"),
        Voice(id: "kokoro_bella", label: "Bella", gender: "female", pack: "af_bella"),
        Voice(id: "kokoro_michael", label: "Michael", gender: "male", pack: "am_michael"),
        Voice(id: "kokoro_emma", label: "Emma", gender: "female", pack: "bf_emma"),
        Voice(id: "kokoro_george", label: "George", gender: "male", pack: "bm_george"),
    ]
    private static let languageCode = "en"

    private let queue = DispatchQueue(label: "com.matslindholm.unblock.kokoro-tts.inference")
    private var model: KokoroTTS?

    func availableVoices() async -> [NarrationVoice] {
        Self.catalog.map {
            NarrationVoice(id: $0.id, label: $0.label, language: Self.languageCode,
                           gender: $0.gender, engine: .kokoro)
        }
    }

    func render(text: String, voice: NarrationVoice, settings: NarrationSettings, to url: URL) async throws {
        guard let entry = Self.catalog.first(where: { $0.id == voice.id }) else {
            throw NarrationError.synthesis("Unknown Kokoro voice \(voice.id).")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let model = try self.loadedModel()
                    let audio = try self.synthesize(model: model, pack: entry.pack, text: text)
                    try Audio.writeWav(audio, sampleRate: model.sampleRate, to: url)
                    MLXMemory.reclaim()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func quiesce() {
        queue.sync {}
    }

    // MARK: - Loading & synthesis (all on `queue`)

    private func loadedModel() throws -> KokoroTTS {
        if let model { return model }
        var result: Result<KokoroTTS, Error>!
        let done = DispatchSemaphore(value: 0)
        Task {
            do { result = .success(try await KokoroTTS.fromPretrained(ensuring: Self.catalog.map(\.pack))) }
            catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        let loaded = try result.get()
        model = loaded
        MLXMemory.configure()
        return loaded
    }

    /// Splits the script into pause-delimited blocks, renders each whole, then
    /// rejoins blocks with silence.
    private func synthesize(model: KokoroTTS, pack: String, text: String) throws -> [Float] {
        var blocks: [[Float]] = []
        for block in text.components(separatedBy: NarrationScript.pauseToken) {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let audio = try autoreleasepool { try model.generate(trimmed, voice: pack).0 }
            if !audio.isEmpty { blocks.append(audio) }
        }
        guard !blocks.isEmpty else {
            throw NarrationError.synthesis("No speech was produced; the text appears to be empty.")
        }
        return Self.joinWithPauses(blocks, sampleRate: model.sampleRate)
    }

    private static func joinWithPauses(_ blocks: [[Float]], sampleRate: Int) -> [Float] {
        let silence = [Float](repeating: 0, count: Int(Double(sampleRate) * NarrationScript.pauseSeconds))
        var out: [Float] = []
        for (index, block) in blocks.enumerated() {
            out.append(contentsOf: block)
            if index < blocks.count - 1 { out.append(contentsOf: silence) }
        }
        return out
    }
}

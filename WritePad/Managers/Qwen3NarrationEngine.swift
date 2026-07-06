import Foundation
import Qwen3TTS

/// In-process Qwen3-TTS engine for the cloned German voices (Nina, Narrator).
/// Loads the model once and renders from a prebuilt voice library bundled with
/// the app (x-vector + ICL codes as `.npy`), so no reference audio is decoded at
/// runtime. MLX corrupts its state under concurrent use, so every model touch
/// runs on one dedicated serial queue.
nonisolated final class Qwen3NarrationEngine: NarrationEngine, @unchecked Sendable {
    private struct Voice {
        let id: String
        let label: String
        let gender: String
        let libraryName: String
    }

    private static let catalog = [
        Voice(id: "qwen3_nina", label: "Nina", gender: "female", libraryName: "de-Nina"),
        Voice(id: "qwen3_narrator", label: "Narrator", gender: "male", libraryName: "de-Narrator"),
    ]
    private static let languageCode = "de"
    private static let voiceLibraryResource = "Qwen3Voices"

    // One sentence per generation, never merged: Qwen3 clones via in-context
    // learning and its alignment drifts on long multi-sentence runs. Only a
    // genuinely over-long sentence is split, at clause boundaries.
    private static let maxChunkChars = 300
    // At the 12 Hz codec a ≤300-char clause decodes to ~250 frames; the ceiling
    // only bounds a *runaway* generation that never emits EOS. 4096 frames
    // (~5 min of audio for one clause) let a single runaway balloon the talker
    // KV cache and codec decode into a multi-GB transient that jetsam kills on
    // an 8 GB iPad. 640 keeps >2× headroom over any real clause while capping
    // that spike ~6×. `renderWithRetry` splits only on thrown errors, so this is
    // the one guard against a non-terminating decode.
    private static let maxNewTokens = 640
    // Qwen3 leaves almost no trailing silence, so sentences need a small gap —
    // shorter than the block/scene pause, so the rhythm stays hierarchical. The
    // coordinator reads this to gap adjacent sentence chunks during assembly.
    static let sentencePauseSeconds = 0.3

    private let queue = DispatchQueue(label: "com.matslindholm.unblock.qwen3-tts.inference")
    private var model: Qwen3TTS?
    private var library: VoiceLibrary?
    private var resolvedCache: [String: VoiceLibrary.Resolved] = [:]

    func availableVoices() async -> [NarrationVoice] {
        guard bundleLibraryURL != nil else { return [] }
        return Self.catalog.map {
            NarrationVoice(id: $0.id, label: $0.label, language: Self.languageCode,
                           gender: $0.gender, engine: .qwen3)
        }
    }

    func render(text: String, voice: NarrationVoice, settings: NarrationSettings, to url: URL) async throws {
        guard let entry = Self.catalog.first(where: { $0.id == voice.id }) else {
            throw NarrationError.synthesis("Unknown Qwen3 voice \(voice.id).")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let model = try self.loadedModel()
                    let resolved = try self.resolvedVoice(entry)
                    let audio = try self.synthesize(model: model, resolved: resolved, text: text)
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

    // MARK: - Loading (all on `queue`)

    /// The bundled voice library ships as a folder reference, so look it up under
    /// the resource directory directly.
    private var bundleLibraryURL: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent(Self.voiceLibraryResource),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
        else { return nil }
        return dir
    }

    private func loadedModel() throws -> Qwen3TTS {
        if let model { return model }
        var result: Result<Qwen3TTS, Error>!
        let done = DispatchSemaphore(value: 0)
        Task {
            do { result = .success(try await Qwen3TTS.fromPretrained(quantizeBits: 8)) }
            catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        let loaded = try result.get()
        model = loaded
        MLXMemory.configure()
        return loaded
    }

    private func resolvedVoice(_ entry: Voice) throws -> VoiceLibrary.Resolved {
        if let cached = resolvedCache[entry.id] { return cached }
        guard let url = bundleLibraryURL else {
            throw NarrationError.synthesis("Qwen3 voice library is missing from the app bundle.")
        }
        let lib = try library ?? VoiceLibrary(url.path)
        library = lib
        let resolved = try lib.resolve(entry.libraryName)
        resolvedCache[entry.id] = resolved
        return resolved
    }

    // MARK: - Synthesis (all on `queue`)

    /// Three-level rhythm: a long sentence's clause chunks concatenate gap-free,
    /// sentences within a block join with `sentencePauseSeconds`, and blocks
    /// (title, scene breaks) with the longer `NarrationScript.pauseSeconds`.
    private func synthesize(model: Qwen3TTS, resolved: VoiceLibrary.Resolved, text: String) throws -> [Float] {
        var blocks: [[Float]] = []
        for block in text.components(separatedBy: NarrationScript.pauseToken) {
            var sentences: [[Float]] = []
            for sentence in Self.sentences(in: block) {
                var audio: [Float] = []
                for chunk in Self.wrapLongSentence(sentence) {
                    let clause = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clause.isEmpty { continue }
                    audio.append(contentsOf: try renderWithRetry(model: model, resolved: resolved, text: clause))
                }
                if !audio.isEmpty { sentences.append(audio) }
            }
            let blockAudio = Self.join(sentences, gapSeconds: Self.sentencePauseSeconds, sampleRate: model.sampleRate)
            if !blockAudio.isEmpty { blocks.append(blockAudio) }
        }
        guard !blocks.isEmpty else {
            throw NarrationError.synthesis("No speech was produced; the text appears to be empty.")
        }
        return Self.join(blocks, gapSeconds: NarrationScript.pauseSeconds, sampleRate: model.sampleRate)
    }

    /// Renders one chunk; on a model failure, halves it by words and retries.
    private func renderWithRetry(model: Qwen3TTS, resolved: VoiceLibrary.Resolved, text: String) throws -> [Float] {
        do {
            return try autoreleasepool {
                let (audio, _) = try model.generate(
                    text, language: resolved.language,
                    refText: resolved.refText, refCode: resolved.refCode,
                    voiceEmbedding: resolved.voiceEmbedding, maxNewTokens: Self.maxNewTokens)
                return audio
            }
        } catch {
            let words = text.split(separator: " ").map(String.init)
            guard words.count > 1 else { throw error }
            let mid = words.count / 2
            let left = try renderWithRetry(model: model, resolved: resolved,
                                           text: words[..<mid].joined(separator: " "))
            let right = try renderWithRetry(model: model, resolved: resolved,
                                            text: words[mid...].joined(separator: " "))
            return left + right
        }
    }

    // MARK: - Text chunking

    private static func sentences(in text: String) -> [String] {
        splitRegex(text.trimmingCharacters(in: .whitespacesAndNewlines), #"(?<=[.!?])\s+"#)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func wrapLongSentence(_ sentence: String) -> [String] {
        if sentence.count <= maxChunkChars { return [sentence] }
        var out: [String] = []
        for raw in splitRegex(sentence, #"(?<=[,;:—–])\s+"#) {
            let clause = raw.trimmingCharacters(in: .whitespaces)
            if clause.isEmpty { continue }
            out.append(contentsOf: clause.count <= maxChunkChars ? [clause] : wrapWords(clause))
        }
        return out.isEmpty ? [sentence] : out
    }

    private static func wrapWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            if !current.isEmpty, current.count + word.count + 1 > maxChunkChars {
                out.append(current)
                current = word
            } else {
                current = current.isEmpty ? word : current + " " + word
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func splitRegex(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        var out: [String] = []
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    private static func join(_ segments: [[Float]], gapSeconds: Double, sampleRate: Int) -> [Float] {
        let silence = [Float](repeating: 0, count: Int(Double(sampleRate) * gapSeconds))
        var out: [Float] = []
        for (index, segment) in segments.enumerated() {
            out.append(contentsOf: segment)
            if index < segments.count - 1 { out.append(contentsOf: silence) }
        }
        return out
    }
}

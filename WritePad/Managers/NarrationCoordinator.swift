import Foundation
import Observation
import KokoroTTS  // for Audio.writeWav (shared WAV writer)

/// Drives chapter narration on a per-chunk cache. A chapter is split into chunks
/// (sentences for Qwen3, paragraphs for Kokoro); each chunk's audio is rendered
/// once and cached content-addressed, then chunks are concatenated with the pause
/// hierarchy into the chapter's audio. Replaying, resuming, or re-narrating after
/// a repo update reuses every unchanged chunk — only new text is rendered.
@MainActor
@Observable
final class NarrationCoordinator {
    /// Silence between adjacent paragraph chunks (Kokoro). Shorter than a scene
    /// break, approximating the pause a reader takes between paragraphs.
    private nonisolated static let paragraphGapSeconds = 0.3

    enum Phase: Equatable {
        case idle
        case rendering(chapterID: String)
        case playing(chapterID: String)
        case paused(chapterID: String)

        var activeChapterID: String? {
            switch self {
            case .idle: return nil
            case .rendering(let id), .playing(let id), .paused(let id): return id
            }
        }
    }

    /// Chunk-level progress of the chapter being generated, so the row can show a
    /// determinate wheel. `completed` starts at the count already cached (they
    /// jump in at once), then fills as the rest render.
    struct ChunkProgress: Equatable {
        let chapterID: String
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    private(set) var phase: Phase = .idle
    private(set) var chunkProgress: ChunkProgress?
    private(set) var errorMessage: String?

    private let kokoro = KokoroNarrationEngine()
    private let qwen3 = Qwen3NarrationEngine()
    private let player = AudioPreviewPlayer()

    init() {
        player.onFinish = { [weak self] in self?.phase = .idle }
    }

    /// English → Kokoro, otherwise Qwen3 (German voices).
    func engine(for languageCode: String?) -> NarrationEngine {
        NarrationScript.isEnglish(languageCode) ? kokoro : qwen3
    }

    func voices(for languageCode: String?) async -> [NarrationVoice] {
        await engine(for: languageCode).availableVoices()
    }

    func defaultVoice(for languageCode: String?) async -> NarrationVoice? {
        await voices(for: languageCode).first
    }

    /// Busy = the model is running or audio is playing. A paused chapter is not
    /// busy: it can be resumed, and another chapter can be started.
    var isBusy: Bool {
        switch phase {
        case .rendering, .playing: return true
        case .idle, .paused: return false
        }
    }

    /// Starts, resumes, or replays `chapter` with `voice`. Renders only the
    /// chunks whose audio is missing (new or changed text); everything else is
    /// reused from the content-addressed cache.
    func narrate(chapter: Chapter, in manuscript: Manuscript, voice: NarrationVoice, storageKey: String) async {
        if case .paused(let id) = phase, id == chapter.id {
            player.resume()
            phase = .playing(chapterID: chapter.id)
            return
        }
        guard !isBusy else { return }
        errorMessage = nil

        let store = NarrationStore(projectKey: storageKey)
        let chunks = ChapterChunker.chunks(
            title: chapter.title, body: chapter.text, voice: voice, languageCode: manuscript.languageCode)
        let audible = chunks.filter(\.isAudible)
        guard !audible.isEmpty else {
            errorMessage = "This chapter has no text to narrate."
            return
        }
        let hashes = audible.map(\.hash)

        // Up to date: assembled file exists and was built from exactly these
        // chunks (same text, same voice) — play it, no model run.
        if let assembled = store.existingChapterAudio(chapterID: chapter.id),
           store.loadChunkManifest(chapterID: chapter.id) == hashes {
            play(assembled, chapterID: chapter.id)
            return
        }

        await generateAndPlay(chapter: chapter, chunks: chunks, audible: audible,
                              hashes: hashes, voice: voice, manuscript: manuscript, store: store)
    }

    /// Pauses playback at the current position; `narrate` on the same chapter resumes it.
    func pause() {
        guard case .playing(let id) = phase else { return }
        player.pause()
        phase = .paused(chapterID: id)
    }

    func stop() {
        player.stop()
        phase = .idle
    }

    func prepareForTermination() {
        player.stop()
        kokoro.quiesce()
        qwen3.quiesce()
    }

    // MARK: - Generation

    private func generateAndPlay(chapter: Chapter, chunks: [AudioChunk], audible: [AudioChunk],
                                 hashes: [String], voice: NarrationVoice, manuscript: Manuscript,
                                 store: NarrationStore) async {
        phase = .rendering(chapterID: chapter.id)
        let cached = audible.filter { store.chunkExists(hash: $0.hash) }.count
        chunkProgress = ChunkProgress(chapterID: chapter.id, completed: cached, total: audible.count)
        // MLX's buffer cache is capped, so reclaiming once per chapter keeps it
        // warm across the chapter's renders without growing memory. Runs on
        // success and failure alike, so a cancelled chapter still frees buffers.
        defer { chunkProgress = nil; MLXMemory.reclaim() }

        let engine = engine(for: manuscript.languageCode)
        do {
            try store.prepareChunkDirectory()
            var completed = cached
            for chunk in audible {
                if !store.chunkExists(hash: chunk.hash) {
                    let url = store.chunkURL(hash: chunk.hash)
                    try await engine.render(text: chunk.spokenText, voice: voice,
                                            settings: NarrationSettings(), to: url)
                    guard phase == .rendering(chapterID: chapter.id) else { return }   // stopped
                    completed += 1
                    chunkProgress?.completed = completed
                }
            }

            let outURL = try store.chapterAudioURL(chapterID: chapter.id)
            // Loading every chunk's WAV and concatenating hundreds of MB of
            // samples is seconds of blocking work — off the main actor.
            try await Task.detached(priority: .userInitiated) {
                let (samples, sampleRate) = try Self.assemble(chunks: chunks, voice: voice, store: store)
                try Audio.writeWav(samples, sampleRate: sampleRate, to: outURL)
            }.value
            try store.saveChunkManifest(hashes, chapterID: chapter.id)
            store.collectGarbageChunks()

            guard phase == .rendering(chapterID: chapter.id) else { return }
            play(outURL, chapterID: chapter.id)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    /// Concatenates the chunks' cached audio: a scene-break pause for `sceneBreak`
    /// chunks, a break pause after the heading, and the engine's speech gap
    /// between adjacent spoken chunks. Touches no instance state, so it runs off
    /// the main actor.
    private nonisolated static func assemble(chunks: [AudioChunk], voice: NarrationVoice,
                                             store: NarrationStore) throws -> (samples: [Float], sampleRate: Int) {
        enum Segment { case audio([Float]); case silence(Double) }
        let breakPause = NarrationScript.pauseSeconds
        let speechGap = voice.engine == .qwen3 ? Qwen3NarrationEngine.sentencePauseSeconds : paragraphGapSeconds

        var segments: [Segment] = []
        var sampleRate = 0
        var previousAudibleKind: AudioChunk.Kind?
        for chunk in chunks {
            switch chunk.kind {
            case .sceneBreak:
                segments.append(.silence(breakPause))
                previousAudibleKind = nil
            case .heading, .speech:
                if let previousAudibleKind {
                    segments.append(.silence(previousAudibleKind == .heading ? breakPause : speechGap))
                }
                guard let loaded = store.loadSamples(at: store.chunkURL(hash: chunk.hash)) else {
                    throw NarrationError.synthesis("Missing audio for a chunk; try regenerating the chapter.")
                }
                if sampleRate == 0 { sampleRate = loaded.sampleRate }
                segments.append(.audio(loaded.samples))
                previousAudibleKind = chunk.kind
            }
        }
        guard sampleRate > 0 else {
            throw NarrationError.synthesis("No speech was produced; the text appears to be empty.")
        }

        let total = segments.reduce(0) { sum, segment in
            switch segment {
            case .audio(let s): return sum + s.count
            case .silence(let seconds): return sum + Int(Double(sampleRate) * seconds)
            }
        }
        var out: [Float] = []
        out.reserveCapacity(total)
        for segment in segments {
            switch segment {
            case .audio(let s): out.append(contentsOf: s)
            case .silence(let seconds): out.append(contentsOf: repeatElement(0, count: Int(Double(sampleRate) * seconds)))
            }
        }
        return (out, sampleRate)
    }

    private func play(_ url: URL, chapterID: String) {
        do {
            try player.play(url: url)
            phase = .playing(chapterID: chapterID)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }
}

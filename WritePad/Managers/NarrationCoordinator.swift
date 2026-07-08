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

    /// Globally-unique chapter identity. `Chapter.id` (the frontmatter id) is
    /// unique only *within* a book, so it must be paired with the book's storage
    /// key — otherwise "ch001" in one book matches "ch001" in another and the
    /// player controls the wrong (still-playing) chapter after switching books.
    struct ChapterRef: Hashable, Sendable {
        let projectKey: String
        let chapterID: String
    }

    enum Phase: Equatable {
        case idle
        case rendering(ChapterRef)
        case playing(ChapterRef)
        case paused(ChapterRef)

        var active: ChapterRef? {
            switch self {
            case .idle: return nil
            case .rendering(let ref), .playing(let ref), .paused(let ref): return ref
            }
        }
    }

    /// Chunk-level progress of the chapter being generated, so the row can show a
    /// determinate wheel. `completed` starts at the count already cached (they
    /// jump in at once), then fills as the rest render.
    struct ChunkProgress: Equatable {
        let ref: ChapterRef
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Where a chapter sits in the background generation pipeline, for the row UI.
    enum BackgroundStatus: Equatable {
        case idle
        case queued
        case rendering(completed: Int, total: Int)
    }

    private struct BackgroundJob: Equatable {
        let ref: ChapterRef
        let chapter: Chapter
        let voice: NarrationVoice
        let languageCode: String?
    }

    /// What's needed to continue playing after a chapter ends: the book's chapter
    /// order and the voice to render the next chapter with. Captured whenever a
    /// chapter starts, so `onFinish` can roll into the next one automatically.
    private struct PlaybackContext {
        let manuscript: Manuscript
        let voice: NarrationVoice
        let storageKey: String
    }

    /// Read-along timeline still to be built for an assembled chapter.
    private struct TimelineJob: Equatable {
        let ref: ChapterRef
        let chapter: Chapter
        let languageCode: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var chunkProgress: ChunkProgress?
    private(set) var errorMessage: String?

    /// Background generation, kept off the interactive path. Interactive playback
    /// always wins the model: the worker parks while a foreground render runs.
    private(set) var backgroundRendering: ChunkProgress?
    /// Bumped whenever a chapter's audio finishes assembling or its read-along
    /// timeline finishes transcribing (interactive or background), so views can
    /// refresh their per-chapter "ready" indicators.
    private(set) var generationStamp = 0
    private var backgroundJobs: [BackgroundJob] = []
    private var backgroundTask: Task<Void, Never>?
    private var cancelledBackgroundRefs: Set<ChapterRef> = []
    /// True only while a *background* chunk render is actually in flight, so an
    /// interactive render can wait for it to finish before touching the model
    /// (never two generations at once — the memory spike would jetsam the app).
    private var backgroundRenderingChunk = false
    /// True while the app is backgrounded. iOS kills an app that submits GPU
    /// (Metal/MLX) work in the background, so all rendering parks until the app
    /// returns to the foreground.
    private var isBackgrounded = false

    /// Auto-created read-along timelines, built off the interactive path so
    /// opening read-along on a generated chapter is instant.
    private var timelineJobs: [TimelineJob] = []
    private var timelineTask: Task<Void, Never>?
    private let timing = WordTimingService()

    /// The book and voice currently playing, so playback can roll into the next
    /// chapter when the current one ends.
    private var playbackContext: PlaybackContext?

    private let pronunciation: PronunciationSettings
    private let kokoro = KokoroNarrationEngine()
    private let qwen3 = Qwen3NarrationEngine()
    private let player = AudioPreviewPlayer()

    init(pronunciation: PronunciationSettings) {
        self.pronunciation = pronunciation
        player.onFinish = { [weak self] in self?.handlePlaybackFinished() }
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
        let ref = ChapterRef(projectKey: storageKey, chapterID: chapter.id)
        // Remember what to play next when this chapter ends.
        playbackContext = PlaybackContext(manuscript: manuscript, voice: voice, storageKey: storageKey)

        // Resume the same paused chapter (same book *and* same chapter).
        if case .paused(let paused) = phase, paused == ref {
            player.resume()
            phase = .playing(ref)
            return
        }
        // A render occupies the single model queue — never preempt it.
        if case .rendering = phase { return }
        // Tapping a different chapter while one plays switches to it: stop the
        // old playback so the new chapter can start (or replay from cache).
        if case .playing(let current) = phase, current != ref {
            player.stop()
            phase = .idle
        }
        guard !isBusy else { return }
        errorMessage = nil

        let store = NarrationStore(projectKey: storageKey)
        let chunks = ChapterChunker.chunks(
            title: chapter.title, body: chapter.text, voice: voice, languageCode: manuscript.languageCode,
            substitutions: pronunciation.substitutions(for: manuscript.languageCode))
        let audible = chunks.filter(\.isAudible)
        guard !audible.isEmpty else {
            errorMessage = "This chapter has no text to narrate."
            return
        }
        let hashes = audible.map(\.hash)

        // Pull the chapter's audio + metadata down from iCloud first (no-op for
        // local storage), so the up-to-date check below reads a real manifest
        // instead of an evicted placeholder and plays the synced audio rather
        // than re-rendering it.
        await store.ensureChapterDownloaded(chapterID: chapter.id)

        // Up to date: assembled file exists and was built from exactly these
        // chunks (same text, same voice) — play it, no model run.
        if let assembled = store.existingChapterAudio(chapterID: chapter.id),
           store.loadChunkManifest(chapterID: chapter.id) == hashes {
            // Audio generated before this build may lack a timeline; make one so
            // read-along and markers work on it too.
            if !store.hasTimeline(chapterID: chapter.id) {
                enqueueTimeline(chapter: chapter, in: ref, languageCode: manuscript.languageCode)
            }
            play(assembled, ref: ref)
            return
        }

        await generateAndPlay(chapter: chapter, chunks: chunks, audible: audible,
                              hashes: hashes, voice: voice, manuscript: manuscript, store: store, ref: ref)
    }

    /// Pauses playback at the current position; `narrate` on the same chapter resumes it.
    func pause() {
        guard case .playing(let ref) = phase else { return }
        player.pause()
        phase = .paused(ref)
    }

    func stop() {
        player.stop()
        phase = .idle
    }

    func prepareForTermination() {
        cancelAllBackground()
        timelineTask?.cancel()
        timelineJobs.removeAll()
        player.stop()
        kokoro.quiesce()
        qwen3.quiesce()
    }

    /// A chapter finished playing on its own: roll into the next chapter of the
    /// same book so listening runs back to back. Explicit stops don't reach here
    /// (they never fire the finish delegate).
    private func handlePlaybackFinished() {
        guard case .playing(let ref) = phase else { return }
        phase = .idle
        guard let context = playbackContext,
              let index = context.manuscript.chapters.firstIndex(where: { $0.id == ref.chapterID })
        else { return }
        // Roll into the next chapter that already has audio, so back-to-back
        // listening never stalls on an un-generated chapter's model spin-up.
        let store = NarrationStore(projectKey: context.storageKey)
        guard let next = context.manuscript.chapters[(index + 1)...].first(where: {
            store.existingChapterAudio(chapterID: $0.id) != nil
        }) else { return }
        Task {
            await narrate(chapter: next, in: context.manuscript,
                          voice: context.voice, storageKey: context.storageKey)
        }
    }

    // MARK: - Markers

    /// Drops a marker at the current playback position of the chapter now
    /// playing, recording the surrounding words from its read-along timeline.
    /// Returns the marker, or nil if nothing is playing.
    @discardableResult
    func addMarker() -> ChapterMarker? {
        guard case .playing(let ref) = phase,
              let chapter = playbackContext?.manuscript.chapters.first(where: { $0.id == ref.chapterID })
        else { return nil }
        let store = NarrationStore(projectKey: ref.projectKey)
        let time = player.currentTime
        let context = MarkerContext.text(around: time, in: store.loadTimeline(chapterID: chapter.id)?.words ?? [])
        let marker = ChapterMarker(time: time, context: context)
        store.appendMarker(marker, chapterID: chapter.id)
        return marker
    }

    // MARK: - Background queue

    var isBackgroundActive: Bool { backgroundRendering != nil || !backgroundJobs.isEmpty }

    /// Chapters waiting in the background generation queue (not counting the one
    /// currently rendering), for the activity readout.
    var queuedGenerationCount: Int { backgroundJobs.count }

    /// Background pipeline state for one chapter, for the row indicator.
    func backgroundStatus(for ref: ChapterRef) -> BackgroundStatus {
        if let current = backgroundRendering, current.ref == ref {
            return .rendering(completed: current.completed, total: current.total)
        }
        return backgroundJobs.contains { $0.ref == ref } ? .queued : .idle
    }

    /// Queues chapters for background generation, skipping any already up to date
    /// or already queued. Idempotent per chapter; starts the worker if idle.
    func enqueueForGeneration(_ chapters: [Chapter], in manuscript: Manuscript,
                              voice: NarrationVoice, storageKey: String) {
        let store = NarrationStore(projectKey: storageKey)
        for chapter in chapters {
            let ref = ChapterRef(projectKey: storageKey, chapterID: chapter.id)
            if backgroundRendering?.ref == ref || backgroundJobs.contains(where: { $0.ref == ref }) { continue }
            let hashes = audibleHashes(for: chapter, voice: voice, languageCode: manuscript.languageCode)
            guard !hashes.isEmpty else { continue }
            if store.chapterStatus(chapterID: chapter.id, hashes: hashes) == .ready { continue }
            cancelledBackgroundRefs.remove(ref)
            backgroundJobs.append(BackgroundJob(ref: ref, chapter: chapter,
                                                voice: voice, languageCode: manuscript.languageCode))
        }
        startBackgroundIfNeeded()
    }

    /// Queues only chapters that were generated before but are now out of date —
    /// used after a repo refresh to auto-repair chapters whose text changed.
    func enqueueOutdatedChapters(_ chapters: [Chapter], in manuscript: Manuscript,
                                 voice: NarrationVoice, storageKey: String) {
        let store = NarrationStore(projectKey: storageKey)
        let outdated = chapters.filter { chapter in
            guard store.loadChunkManifest(chapterID: chapter.id) != nil else { return false }
            let hashes = audibleHashes(for: chapter, voice: voice, languageCode: manuscript.languageCode)
            return !hashes.isEmpty && store.chapterStatus(chapterID: chapter.id, hashes: hashes) != .ready
        }
        enqueueForGeneration(outdated, in: manuscript, voice: voice, storageKey: storageKey)
    }

    func cancelBackground(_ ref: ChapterRef) {
        backgroundJobs.removeAll { $0.ref == ref }
        if backgroundRendering?.ref == ref { cancelledBackgroundRefs.insert(ref) }
    }

    func cancelAllBackground() {
        backgroundJobs.removeAll()
        if let current = backgroundRendering?.ref { cancelledBackgroundRefs.insert(current) }
    }

    /// The app entered the background: stop starting new renders (GPU work is
    /// forbidden there). Any chunk already in flight finishes within the
    /// system's grace period; the worker parks before the next one.
    func handleEnteredBackground() { isBackgrounded = true }

    /// The app returned to the foreground: resume queued generation.
    func handleEnteringForeground() {
        isBackgrounded = false
        startBackgroundIfNeeded()
    }

    /// Renders a short sample with the current pronunciation rules applied, for
    /// auditioning in Settings. Returns a temp WAV URL, or nil if no voice is
    /// available or the sample is empty. Shares the engines' serial queue, so it
    /// never renders concurrently with narration.
    func renderSample(_ text: String, languageCode: String?) async throws -> URL? {
        guard let voice = await defaultVoice(for: languageCode) else { return nil }
        let spoken = NarrationScript.prepareBody(
            text, languageCode: languageCode, substitutions: pronunciation.substitutions(for: languageCode))
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        await parkBackground()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pron-preview-\(UUID().uuidString).wav")
        try await engine(for: languageCode).render(
            text: spoken, voice: voice, settings: NarrationSettings(), to: url)
        MLXMemory.reclaim()
        return url
    }

    /// Renders a sample with a specific speaker, so the auditioning UI can pick a
    /// voice rather than always using the language default. Rules are applied in
    /// the voice's own language.
    func renderSample(_ text: String, voice: NarrationVoice) async throws -> URL? {
        let languageCode = voice.language
        let spoken = NarrationScript.prepareBody(
            text, languageCode: languageCode, substitutions: pronunciation.substitutions(for: languageCode))
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        await parkBackground()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pron-preview-\(UUID().uuidString).wav")
        try await engine(for: languageCode).render(
            text: spoken, voice: voice, settings: NarrationSettings(), to: url)
        MLXMemory.reclaim()
        return url
    }

    // MARK: - Read-along timelines

    /// Number of chapters whose read-along timeline is still being (or waiting to
    /// be) built, for the activity readout.
    var pendingTimelineCount: Int { timelineJobs.count }

    /// Enqueues read-along timelines for any chapters that already have audio but
    /// no timeline yet — e.g. audio generated in a previous session, before this
    /// build, or whose transcription was interrupted. Called on load so a book's
    /// read-along data finishes building on its own, not only when a chapter is
    /// opened.
    func ensureTimelines(for chapters: [Chapter], languageCode: String?, storageKey: String) {
        let store = NarrationStore(projectKey: storageKey)
        for chapter in chapters where store.existingChapterAudio(chapterID: chapter.id) != nil
            && !store.hasTimeline(chapterID: chapter.id) {
            enqueueTimeline(chapter: chapter,
                            in: ChapterRef(projectKey: storageKey, chapterID: chapter.id),
                            languageCode: languageCode)
        }
    }

    /// Queues a chapter's read-along timeline to be transcribed and cached off
    /// the interactive path. Idempotent per chapter; starts the worker if idle.
    private func enqueueTimeline(chapter: Chapter, in ref: ChapterRef, languageCode: String?) {
        guard !timelineJobs.contains(where: { $0.ref == ref }) else { return }
        timelineJobs.append(TimelineJob(ref: ref, chapter: chapter, languageCode: languageCode))
        if timelineTask == nil {
            timelineTask = Task { [weak self] in await self?.runTimelineQueue() }
        }
    }

    /// Builds queued timelines one at a time (Speech recognition is serialized to
    /// itself) and parks while the app is backgrounded.
    private func runTimelineQueue() async {
        defer { timelineTask = nil }
        while !timelineJobs.isEmpty {
            let job = timelineJobs.removeFirst()
            // Transcription loads its own model; keep it off the GPU renders'
            // back and out of the background (where Speech is suspended anyway).
            while isInteractiveRendering || backgroundRenderingChunk || isBackgrounded {
                try? await Task.sleep(for: .milliseconds(300))
            }
            let store = NarrationStore(projectKey: job.ref.projectKey)
            guard let audioURL = store.existingChapterAudio(chapterID: job.chapter.id) else { continue }
            await NarrationStorage.ensureDownloaded(audioURL)   // fetch from iCloud if needed
            let tokens = NarrationScript.tokens(title: job.chapter.title, body: job.chapter.text)
            do {
                let timeline = try await timing.timeline(
                    audioURL: audioURL, tokens: tokens, languageCode: job.languageCode,
                    cached: store.loadTimeline(chapterID: job.chapter.id))
                try? store.saveTimeline(timeline, chapterID: job.chapter.id)
                // Let the row's "fully processed" badge light up now the
                // read-along timeline exists.
                generationStamp &+= 1
            } catch {
                // Best-effort: read-along still builds the timeline on demand.
            }
        }
    }

    private func audibleHashes(for chapter: Chapter, voice: NarrationVoice, languageCode: String?) -> [String] {
        ChapterChunker.chunks(title: chapter.title, body: chapter.text, voice: voice, languageCode: languageCode,
                              substitutions: pronunciation.substitutions(for: languageCode))
            .filter(\.isAudible).map(\.hash)
    }

    private func startBackgroundIfNeeded() {
        guard backgroundTask == nil, !backgroundJobs.isEmpty else { return }
        backgroundTask = Task { [weak self] in await self?.runBackgroundQueue() }
    }

    private func runBackgroundQueue() async {
        defer { backgroundTask = nil; backgroundRendering = nil; MLXMemory.reclaim() }
        while !backgroundJobs.isEmpty {
            let job = backgroundJobs.removeFirst()
            if cancelledBackgroundRefs.remove(job.ref) != nil { continue }
            await renderInBackground(job)
        }
    }

    private func renderInBackground(_ job: BackgroundJob) async {
        let store = NarrationStore(projectKey: job.ref.projectKey)
        let chunks = ChapterChunker.chunks(
            title: job.chapter.title, body: job.chapter.text, voice: job.voice, languageCode: job.languageCode,
            substitutions: pronunciation.substitutions(for: job.languageCode))
        let audible = chunks.filter(\.isAudible)
        let hashes = audible.map(\.hash)
        guard !audible.isEmpty else { return }

        let cached = audible.filter { store.chunkExists(hash: $0.hash) }.count
        backgroundRendering = ChunkProgress(ref: job.ref, completed: cached, total: audible.count)
        defer { backgroundRendering = nil; MLXMemory.reclaim() }

        let engine = engine(for: job.languageCode)
        do {
            try store.prepareChunkDirectory()
            var completed = cached
            for chunk in audible where !store.chunkExists(hash: chunk.hash) {
                await awaitBackgroundRunnable()                     // foreground wins; park in background
                if cancelledBackgroundRefs.contains(job.ref) { return }
                backgroundRenderingChunk = true
                defer { backgroundRenderingChunk = false }          // per-iteration, resets on throw too
                try await engine.render(text: chunk.spokenText, voice: job.voice,
                                        settings: NarrationSettings(), to: store.chunkURL(hash: chunk.hash))
                completed += 1
                backgroundRendering?.completed = completed
            }
            await store.ensureChunksDownloaded(hashes: hashes)
            try await assembleAndSave(chapterID: job.ref.chapterID, chunks: chunks,
                                      hashes: hashes, voice: job.voice, store: store)
            enqueueTimeline(chapter: job.chapter, in: job.ref, languageCode: job.languageCode)
            // Safe to reclaim orphaned chunks only when no other generation for
            // this project might still be holding unmanifested chunks.
            if backgroundJobs.isEmpty, !isInteractiveRendering { store.collectGarbageChunks() }
        } catch {
            // Per-chapter failures are silent; the partial cache is kept for retry.
        }
    }

    /// The background worker parks while a foreground render holds the model
    /// (never two generations at once) or while the app is backgrounded (no GPU
    /// work allowed there).
    private func awaitBackgroundRunnable() async {
        while isInteractiveRendering || isBackgrounded {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// A foreground render parks while the app is backgrounded.
    private func awaitForeground() async {
        while isBackgrounded {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Waits for any in-flight background chunk to finish, so an interactive
    /// render can start without a second generation running at the same time.
    private func parkBackground() async {
        while backgroundRenderingChunk {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private var isInteractiveRendering: Bool {
        if case .rendering = phase { return true }
        return false
    }

    // MARK: - Generation

    private func generateAndPlay(chapter: Chapter, chunks: [AudioChunk], audible: [AudioChunk],
                                 hashes: [String], voice: NarrationVoice, manuscript: Manuscript,
                                 store: NarrationStore, ref: ChapterRef) async {
        phase = .rendering(ref)
        cancelBackground(ref)   // foreground takes over this chapter
        let cached = audible.filter { store.chunkExists(hash: $0.hash) }.count
        chunkProgress = ChunkProgress(ref: ref, completed: cached, total: audible.count)
        // MLX's buffer cache is capped, so reclaiming once per chapter keeps it
        // warm across the chapter's renders without growing memory. Runs on
        // success and failure alike, so a cancelled chapter still frees buffers.
        defer { chunkProgress = nil; MLXMemory.reclaim() }

        let engine = engine(for: manuscript.languageCode)
        do {
            try store.prepareChunkDirectory()
            await parkBackground()   // never two generations at once
            var completed = cached
            for chunk in audible {
                if !store.chunkExists(hash: chunk.hash) {
                    await awaitForeground()                          // no GPU work in the background
                    guard phase == .rendering(ref) else { return }   // stopped while parked
                    let url = store.chunkURL(hash: chunk.hash)
                    try await engine.render(text: chunk.spokenText, voice: voice,
                                            settings: NarrationSettings(), to: url)
                    guard phase == .rendering(ref) else { return }   // stopped
                    completed += 1
                    chunkProgress?.completed = completed
                }
            }

            // Chunks reused from iCloud arrive as placeholders; fetch them so
            // assembly can read their samples.
            await store.ensureChunksDownloaded(hashes: hashes)
            let outURL = try await assembleAndSave(
                chapterID: chapter.id, chunks: chunks, hashes: hashes, voice: voice, store: store)
            if !isBackgroundActive { store.collectGarbageChunks() }
            enqueueTimeline(chapter: chapter, in: ref, languageCode: manuscript.languageCode)

            guard phase == .rendering(ref) else { return }
            play(outURL, ref: ref)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    /// Concatenates the chapter's cached chunks into its audio file and records
    /// the manifest it was built from. The load-and-concatenate of hundreds of
    /// MB of samples is blocking work, so it runs off the main actor. Shared by
    /// interactive playback and the background queue.
    @discardableResult
    private func assembleAndSave(chapterID: String, chunks: [AudioChunk], hashes: [String],
                                 voice: NarrationVoice, store: NarrationStore) async throws -> URL {
        let outURL = try store.chapterAudioURL(chapterID: chapterID)
        try await Task.detached(priority: .userInitiated) {
            let (samples, sampleRate) = try Self.assemble(chunks: chunks, voice: voice, store: store)
            try Audio.writeWav(samples, sampleRate: sampleRate, to: outURL)
        }.value
        try store.saveChunkManifest(hashes, chapterID: chapterID)
        generationStamp &+= 1
        return outURL
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

    private func play(_ url: URL, ref: ChapterRef) {
        do {
            try player.play(url: url)
            phase = .playing(ref)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }
}

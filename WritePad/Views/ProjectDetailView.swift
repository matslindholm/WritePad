import SwiftUI

/// A checked-out book: its chapters, a refresh control to keep the clone recent,
/// a voice picker, and per-chapter narration.
struct ProjectDetailView: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(NarrationCoordinator.self) private var narration
    @Environment(PronunciationSettings.self) private var pronunciation

    let project: BookProject

    @State private var manuscript: Manuscript?
    @State private var loadState: LoadState = .loading
    @State private var errorMessage: String?
    @State private var voices: [NarrationVoice] = []
    @State private var selectedVoiceID: String?
    @State private var isRefreshing = false
    @State private var audioStatus: [String: NarrationStore.ChapterAudioStatus] = [:]
    /// Whether each chapter's read-along timeline has finished transcribing, so
    /// the row's "fully processed" check waits for audio *and* read-along.
    @State private var timelineReady: [String: Bool] = [:]
    @State private var readingChapter: Chapter?
    @State private var markerFlash = false
    @State private var flashTask: Task<Void, Never>?

    private enum LoadState { case loading, loaded, failed }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Reading manuscript…")
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't Read Manuscript", systemImage: "doc.questionmark")
                } description: {
                    Text(errorMessage ?? "Unknown error.")
                }
            case .loaded:
                chapterList
            }
        }
        .navigationTitle(manuscript?.title ?? project.displayTitle)
        .inlineNavigationTitle()
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                NarrationActivityReadout()
                MemoryReadout()
            }
        }
        .task(id: project.id) { await loadManuscript() }
    }

    private var chapterList: some View {
        List(manuscript?.chapters ?? []) { chapter in
            ChapterRow(
                chapter: chapter,
                projectKey: project.folderName,
                phase: narration.phase,
                progress: narration.chunkProgress,
                status: audioStatus[chapter.id] ?? .none,
                readAlongReady: timelineReady[chapter.id] ?? false,
                background: narration.backgroundStatus(for: ref(for: chapter)),
                canNarrate: selectedVoice != nil,
                onPlay: { narrate(chapter) },
                onPause: { narration.pause() },
                onGenerate: { enqueue([chapter]) },
                onCancel: { narration.cancelBackground(ref(for: chapter)) },
                onRead: { startReading(chapter) })
        }
        .onChange(of: selectedVoiceID) { Task { await refreshAudioStatus() } }
        .onChange(of: narration.phase) { Task { await refreshAudioStatus() } }
        .onChange(of: narration.generationStamp) { Task { await refreshAudioStatus() } }
        .onChange(of: pronunciation.rules) { Task { await refreshAudioStatus() } }
        .sheet(item: $readingChapter) { chapter in
            KaraokeReadingView(chapter: chapter, chapters: manuscript?.chapters ?? [],
                               projectKey: project.folderName,
                               languageCode: manuscript?.languageCode)
        }
        .background { markerHotkey }
        .overlay(alignment: .bottom) {
            if let errorMessage = narration.errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.red, in: .rect(cornerRadius: 8))
                    .padding()
            } else if markerFlash {
                Label("Marker added", systemImage: "bookmark.fill")
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.tint, in: .capsule)
                    .padding()
                    .transition(.opacity)
            }
        }
    }

    /// A hidden button that makes Return drop a marker on the chapter now
    /// playing (mirrors the read-along hotkey). Disabled unless a chapter is
    /// playing, and while the read-along sheet owns the keyboard.
    private var markerHotkey: some View {
        Button(action: addMarker) { Color.clear.frame(width: 0, height: 0) }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!isPlaying || readingChapter != nil)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private var isPlaying: Bool {
        if case .playing = narration.phase { return true }
        return false
    }

    private func addMarker() {
        guard narration.addMarker() != nil else { return }
        withAnimation { markerFlash = true }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation { markerFlash = false }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .barTrailing) {
            if voices.count > 1 {
                Picker("Voice", selection: $selectedVoiceID) {
                    ForEach(voices) { voice in
                        Text(voice.label).tag(Optional(voice.id))
                    }
                }
            }
        }
        ToolbarItem(placement: .barTrailing) {
            Menu {
                Button {
                    if let chapters = manuscript?.chapters { enqueue(chapters) }
                } label: {
                    Label("Generate All Audio", systemImage: "square.stack.3d.up")
                }
                .disabled(selectedVoice == nil || manuscript == nil)

                if narration.isBackgroundActive {
                    Button(role: .destructive) {
                        narration.cancelAllBackground()
                    } label: {
                        Label("Stop Background Generation", systemImage: "stop.circle")
                    }
                }
            } label: {
                Label("Generate", systemImage: narration.isBackgroundActive
                      ? "waveform.circle.fill" : "waveform")
            }
        }
        ToolbarItem(placement: .barTrailing) {
            Button { Task { await refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
        }
    }

    private var selectedVoice: NarrationVoice? {
        voices.first { $0.id == selectedVoiceID } ?? voices.first
    }

    // MARK: - Actions

    private func loadManuscript() async {
        loadState = .loading
        let url = library.localURL(for: project)
        let fallback = project.displayTitle
        do {
            // A book that arrived via iCloud sync has no local clone yet — fetch
            // it from GitHub before reading the manuscript.
            try await library.ensureCheckedOut(project)
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ChapterReader().read(at: url, fallbackTitle: fallback)
            }.value
            manuscript = loaded
            loadState = .loaded
            voices = await narration.voices(for: loaded.languageCode)
            if selectedVoiceID == nil { selectedVoiceID = voices.first?.id }
            await refreshAudioStatus()
            // Finish (or repair) read-along transcription for chapters whose
            // audio already exists, so the "fully processed" check can complete.
            narration.ensureTimelines(for: loaded.chapters, languageCode: loaded.languageCode,
                                      storageKey: project.folderName)
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    private func ref(for chapter: Chapter) -> NarrationCoordinator.ChapterRef {
        .init(projectKey: project.folderName, chapterID: chapter.id)
    }

    /// Queues chapters for background generation with the selected voice.
    private func enqueue(_ chapters: [Chapter]) {
        guard let voice = selectedVoice, let manuscript else { return }
        narration.enqueueForGeneration(chapters, in: manuscript, voice: voice, storageKey: project.folderName)
    }

    /// Opens the read-along view, yielding the audio session by stopping any
    /// coordinator playback first.
    private func startReading(_ chapter: Chapter) {
        narration.stop()
        readingChapter = chapter
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await library.refresh(project)
            await loadManuscript()
            // Auto-repair chapters whose text changed in this update.
            if let voice = selectedVoice, let manuscript {
                narration.enqueueOutdatedChapters(manuscript.chapters, in: manuscript,
                                                  voice: voice, storageKey: project.folderName)
            }
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    /// Recomputes each chapter's cached-audio status off the main actor (cheap
    /// filesystem + chunk-hash checks). Re-run on load, voice change, and when a
    /// generation finishes.
    private func refreshAudioStatus() async {
        guard let manuscript, let voice = selectedVoice else { return }
        let chapters = manuscript.chapters
        let key = project.folderName
        let lang = manuscript.languageCode
        let subs = pronunciation.substitutions(for: lang)
        let computed = await Task.detached(priority: .utility) {
            let store = NarrationStore(projectKey: key)
            var status: [String: NarrationStore.ChapterAudioStatus] = [:]
            var timelines: [String: Bool] = [:]
            for chapter in chapters {
                let hashes = ChapterChunker
                    .chunks(title: chapter.title, body: chapter.text, voice: voice,
                            languageCode: lang, substitutions: subs)
                    .filter(\.isAudible).map(\.hash)
                status[chapter.id] = store.chapterStatus(chapterID: chapter.id, hashes: hashes)
                timelines[chapter.id] = store.hasTimeline(chapterID: chapter.id)
            }
            return (status, timelines)
        }.value
        audioStatus = computed.0
        timelineReady = computed.1
    }

    private func narrate(_ chapter: Chapter) {
        guard let voice = selectedVoice, let manuscript else { return }
        Task {
            await narration.narrate(chapter: chapter, in: manuscript, voice: voice,
                                    storageKey: project.folderName)
        }
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let projectKey: String
    let phase: NarrationCoordinator.Phase
    let progress: NarrationCoordinator.ChunkProgress?
    let status: NarrationStore.ChapterAudioStatus
    /// Read-along timeline transcribed and cached — the second half of a chapter
    /// being fully processed, after its audio.
    let readAlongReady: Bool
    let background: NarrationCoordinator.BackgroundStatus
    let canNarrate: Bool
    let onPlay: () -> Void
    let onPause: () -> Void
    let onGenerate: () -> Void
    let onCancel: () -> Void
    let onRead: () -> Void

    private var ref: NarrationCoordinator.ChapterRef {
        .init(projectKey: projectKey, chapterID: chapter.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
            control
        }
        .padding(.vertical, 2)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if status == .ready {
            Button { onRead() } label: { Label("Read Along", systemImage: "captions.bubble") }
        }
        switch background {
        case .idle:
            Button { onGenerate() } label: { Label("Generate Audio", systemImage: "waveform") }
                .disabled(!canNarrate)
        case .queued, .rendering:
            Button(role: .destructive) { onCancel() } label: {
                Label("Cancel Generation", systemImage: "xmark.circle")
            }
        }
    }

    /// A hint at how much of this chapter's audio is already on disk. Hidden
    /// while this row is actively rendering (the progress wheel says more).
    @ViewBuilder
    private var statusBadge: some View {
        if case .rendering(let r) = phase, r == ref {
            EmptyView()   // this row's own progress wheel says it
        } else {
            switch background {
            case .rendering(let completed, let total):
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                    .progressViewStyle(.circular)
                    .accessibilityLabel("Generating in background")
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary).imageScale(.small)
                    .accessibilityLabel("Queued for generation")
            case .idle:
                readyBadge
            }
        }
    }

    @ViewBuilder
    private var readyBadge: some View {
        switch status {
        case .ready where readAlongReady:
            // Fully processed: audio *and* read-along both cached.
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).imageScale(.large)
                .accessibilityLabel("Fully processed")
        case .ready:
            // Audio is ready, read-along transcription still pending.
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Preparing read-along")
        case .partial:
            Image(systemName: "circle.bottomhalf.filled")
                .foregroundStyle(.secondary).imageScale(.small)
                .accessibilityLabel("Audio partially generated")
        case .none:
            EmptyView()
        }
    }

    private var subtitle: String {
        if let progress = myProgress {
            return "Generating \(progress.completed)/\(progress.total)…"
        }
        switch background {
        case .rendering(let completed, let total):
            return "Generating in background \(completed)/\(total)…"
        case .queued:
            return "Queued for generation…"
        case .idle:
            return "\(chapter.wordCount) words"
        }
    }

    @ViewBuilder
    private var control: some View {
        switch phase {
        case .rendering(let r) where r == ref:
            if let progress = myProgress, progress.total > 0 {
                ProgressView(value: progress.fraction).progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        case .playing(let r) where r == ref:
            Button(action: onPause) { Image(systemName: "pause.circle.fill") }
                .font(.title2)
        default:
            // idle, paused (resume), or another chapter is active. Tapping while
            // another chapter *plays* switches to this one; only an active render
            // (exclusive model use) blocks it.
            Button(action: onPlay) { Image(systemName: "play.circle.fill") }
                .font(.title2)
                .disabled(!canNarrate || renderingElsewhere)
        }
    }

    private var myProgress: NarrationCoordinator.ChunkProgress? {
        progress?.ref == ref ? progress : nil
    }

    /// A render for a *different* chapter holds the model exclusively.
    private var renderingElsewhere: Bool {
        if case .rendering(let r) = phase { return r != ref }
        return false
    }
}

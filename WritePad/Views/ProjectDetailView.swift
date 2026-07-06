import SwiftUI

/// A checked-out book: its chapters, a refresh control to keep the clone recent,
/// a voice picker, and per-chapter narration.
struct ProjectDetailView: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(NarrationCoordinator.self) private var narration

    let project: BookProject

    @State private var manuscript: Manuscript?
    @State private var loadState: LoadState = .loading
    @State private var errorMessage: String?
    @State private var voices: [NarrationVoice] = []
    @State private var selectedVoiceID: String?
    @State private var isRefreshing = false

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { MemoryReadout() }
        .task(id: project.id) { await loadManuscript() }
    }

    private var chapterList: some View {
        List(manuscript?.chapters ?? []) { chapter in
            ChapterRow(
                chapter: chapter,
                phase: narration.phase,
                progress: narration.chunkProgress,
                canNarrate: selectedVoice != nil,
                onPlay: { narrate(chapter) },
                onPause: { narration.pause() })
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = narration.errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.red, in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if voices.count > 1 {
                Picker("Voice", selection: $selectedVoiceID) {
                    ForEach(voices) { voice in
                        Text(voice.label).tag(Optional(voice.id))
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
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
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ChapterReader().read(at: url, fallbackTitle: fallback)
            }.value
            manuscript = loaded
            loadState = .loaded
            voices = await narration.voices(for: loaded.languageCode)
            if selectedVoiceID == nil { selectedVoiceID = voices.first?.id }
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await library.refresh(project)
            await loadManuscript()
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
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
    let phase: NarrationCoordinator.Phase
    let progress: NarrationCoordinator.ChunkProgress?
    let canNarrate: Bool
    let onPlay: () -> Void
    let onPause: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let progress = myProgress {
            return "Generating \(progress.completed)/\(progress.total)…"
        }
        return "\(chapter.wordCount) words"
    }

    @ViewBuilder
    private var control: some View {
        switch phase {
        case .rendering(let id) where id == chapter.id:
            if let progress = myProgress, progress.total > 0 {
                ProgressView(value: progress.fraction).progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        case .playing(let id) where id == chapter.id:
            Button(action: onPause) { Image(systemName: "pause.circle.fill") }
                .font(.title2)
        default:
            // idle, paused (resume), or another chapter is active.
            Button(action: onPlay) { Image(systemName: "play.circle.fill") }
                .font(.title2)
                .disabled(!canNarrate || busyElsewhere)
        }
    }

    private var myProgress: NarrationCoordinator.ChunkProgress? {
        progress?.chapterID == chapter.id ? progress : nil
    }

    /// The model is running or audio is playing for a *different* chapter.
    private var busyElsewhere: Bool {
        switch phase {
        case .rendering(let id), .playing(let id): return id != chapter.id
        case .idle, .paused: return false
        }
    }
}

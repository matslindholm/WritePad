import AVFoundation
import Observation
import SwiftUI

/// Coordinate space shared by the scroll view and the current word's
/// frame-reporting overlay, so the scroll handler can tell when the spoken word
/// has drifted out of the viewport.
private let karaokeScrollSpace = "karaokeScroll"

/// Carries the current word's frame (in the scroll viewport's space) up to the
/// scroll handler.
private struct CurrentWordFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// Read-along ("karaoke") view: plays a chapter's generated audio while
/// highlighting the word being spoken, using the `ChapterTimeline` derived by
/// `WordTimingService`. Tapping a word seeks the audio there.
struct KaraokeReadingView: View {
    /// Full chapter order, so reading rolls into the next chapter automatically.
    let chapters: [Chapter]
    let projectKey: String
    let languageCode: String?

    @Environment(\.dismiss) private var dismiss
    @State private var current: Chapter
    @State private var player = ReadingPlayer()
    @State private var timing = WordTimingService()
    @State private var paragraphs: [[IndexedWord]] = []
    @State private var words: [WordTiming] = []
    @State private var loadState: LoadState = .loading
    @State private var errorMessage: String?
    @State private var lastActiveIndex = 0
    @State private var markerCount = 0
    @State private var markerFlash = false
    @State private var flashTask: Task<Void, Never>?

    init(chapter: Chapter, chapters: [Chapter], projectKey: String, languageCode: String?) {
        self.chapters = chapters
        self.projectKey = projectKey
        self.languageCode = languageCode
        _current = State(initialValue: chapter)
    }

    private enum LoadState { case loading, ready, failed }

    struct IndexedWord: Identifiable, Equatable { let id: Int; let word: WordTiming }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(current.title)
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .safeAreaInset(edge: .bottom) { if loadState == .ready { controlBar } }
        }
        .macReadingFrame()
        .task { await load() }
        .onChange(of: player.finishTick) { advanceToNextChapter() }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing read-along…\nTranscribing the audio for word timing.")
                    .multilineTextAlignment(.center)
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failed:
            ContentUnavailableView {
                Label("Can't Read Along", systemImage: "text.badge.xmark")
            } description: {
                Text(errorMessage ?? "Unknown error.")
            }
        case .ready:
            transcript
        }
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(paragraphs.indices, id: \.self) { p in
                            FlowLayout(spacing: 6, lineSpacing: 8) {
                                ForEach(paragraphs[p]) { item in
                                    wordView(item)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(.named(karaokeScrollSpace))
                // Reading runs forward, so the spoken word only ever drifts off
                // the bottom — scroll then, easing it into the upper third with
                // room to read on below. The top edge only matters after a
                // backward seek, so only scroll up when the highlight actually
                // jumped back; otherwise the opening words (near the top) would
                // fight the top clamp and jitter.
                .onPreferenceChange(CurrentWordFrameKey.self) { frame in
                    guard let frame, let index = activeIndex else { return }
                    let margin: CGFloat = 64
                    let movedBack = index < lastActiveIndex
                    lastActiveIndex = index
                    let offBottom = frame.maxY > outer.size.height - margin
                    let offTop = movedBack && frame.minY < margin
                    if offBottom || offTop {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.3))
                        }
                    }
                }
            }
        }
    }

    private func wordView(_ item: IndexedWord) -> some View {
        let isActive = item.id == activeIndex
        return Text(item.word.text)
            .font(.title3)
            .fontWeight(item.word.emphasis.isBold ? .bold : .regular)
            .italic(item.word.emphasis.isItalic)
            .foregroundStyle(isActive ? Color.white : .primary)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(isActive ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
            .overlay { if isActive { currentWordFrameReader } }
            .id(item.id)
            .onTapGesture {
                player.seek(to: item.word.start)
                if !player.isPlaying { player.play() }
            }
    }

    /// Reports the current word's position within the scroll viewport so the
    /// grid can scroll it back in only once it drifts out.
    private var currentWordFrameReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CurrentWordFrameKey.self,
                                   value: geometry.frame(in: .named(karaokeScrollSpace)))
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { player.currentTime },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1))
            HStack {
                Text(timeLabel(player.currentTime)).font(.caption).monospacedDigit()
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                Spacer()
                markerButton
            }
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { if markerFlash { markerFlashLabel } }
    }

    /// Drops a marker at the current point. Return is the hardware-keyboard
    /// hotkey for the same, so a listener can mark a spot without reaching for
    /// the screen.
    private var markerButton: some View {
        Button(action: addMarker) {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                if markerCount > 0 {
                    Text("\(markerCount)").monospacedDigit()
                }
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityLabel("Add marker")
    }

    private var markerFlashLabel: some View {
        Label("Marker added", systemImage: "bookmark.fill")
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.tint, in: .capsule)
            .foregroundStyle(.white)
            .padding(.top, 4)
            .transition(.opacity)
    }

    /// Last word whose start time has passed — the one being spoken. The words
    /// are sorted by start, so a binary search keeps this cheap at 20 Hz.
    private var activeIndex: Int? {
        guard !words.isEmpty else { return nil }
        let t = player.currentTime
        var low = 0, high = words.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= t { result = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func load() async {
        loadState = .loading
        lastActiveIndex = 0
        let store = NarrationStore(projectKey: projectKey)
        markerCount = store.loadMarkers(chapterID: current.id).count
        guard let audioURL = store.existingChapterAudio(chapterID: current.id) else {
            errorMessage = "This chapter has no generated audio yet."
            loadState = .failed
            return
        }
        let tokens = NarrationScript.tokens(title: current.title, body: current.text)
        do {
            let timeline = try await timing.timeline(
                audioURL: audioURL, tokens: tokens, languageCode: languageCode,
                cached: store.loadTimeline(chapterID: current.id))
            try? store.saveTimeline(timeline, chapterID: current.id)
            words = timeline.words
            paragraphs = Self.group(timeline.words)
            try player.load(url: audioURL)
            loadState = .ready
            player.play()
        } catch is CancellationError {
            // The sheet was dismissed mid-transcription; nothing to show.
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    /// Records a marker at the current point with the words around it, and
    /// flashes a brief confirmation.
    private func addMarker() {
        guard loadState == .ready else { return }
        let store = NarrationStore(projectKey: projectKey)
        let text = MarkerContext.text(around: player.currentTime, in: words)
        let markers = store.appendMarker(ChapterMarker(time: player.currentTime, context: text), chapterID: current.id)
        markerCount = markers.count
        withAnimation { markerFlash = true }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation { markerFlash = false }
        }
    }

    /// When a chapter finishes, roll into the next one that already has audio, so
    /// listening runs back to back.
    private func advanceToNextChapter() {
        guard let index = chapters.firstIndex(where: { $0.id == current.id }) else { return }
        let store = NarrationStore(projectKey: projectKey)
        guard let next = chapters[(index + 1)...].first(where: {
            store.existingChapterAudio(chapterID: $0.id) != nil
        }) else { return }
        current = next
        Task { await load() }
    }

    /// Groups the flat timeline into paragraphs, keeping each word's global
    /// index for highlighting and scroll targeting.
    private static func group(_ words: [WordTiming]) -> [[IndexedWord]] {
        var paragraphs: [[IndexedWord]] = []
        var current: [IndexedWord] = []
        var currentParagraph: Int?
        for (index, word) in words.enumerated() {
            if let p = currentParagraph, p != word.paragraphIndex, !current.isEmpty {
                paragraphs.append(current)
                current = []
            }
            currentParagraph = word.paragraphIndex
            current.append(IndexedWord(id: index, word: word))
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }
}

/// Playback for the reading session, independent of `NarrationCoordinator`'s
/// player, publishing a live `currentTime` for the highlight to follow.
@MainActor
@Observable
final class ReadingPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Bumped when playback reaches the end on its own (not on manual stop), so
    /// the view can advance to the next chapter without a stored closure that
    /// would retain it.
    private(set) var finishTick = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(url: URL) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        syncTime()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, time), duration)
        currentTime = player.currentTime
    }

    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
    }

    private func syncTime() { if let player { currentTime = player.currentTime } }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.syncTime()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Ignore a delayed finish from a player we've already replaced.
            guard self.player === player else { return }
            self.stopTicker()
            self.isPlaying = false
            self.currentTime = self.duration
            self.finishTick += 1
        }
    }
}

/// Wrapping flow layout: lays out word views left-to-right, wrapping to the
/// next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? 0, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

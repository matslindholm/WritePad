import AVFoundation
import Foundation

/// On-disk cache of a book's generated audio, rooted per project under the
/// caches directory:
/// ```
/// Narration/<projectKey>/
///   chapters/
///     <chapterID>.wav          // assembled chapter audio
///     <chapterID>.chunks.json  // ordered chunk hashes the chapter was built from
///   chunks/
///     <hash>.wav               // cached per-chunk audio, shared across chapters
/// ```
/// The chunk cache is content-addressed, so a repo update that changes a few
/// sentences reuses every unchanged chunk; only new hashes are re-rendered.
struct NarrationStore: Sendable {
    let root: URL
    /// The book's stable key (its clone folder name), used to scope iCloud
    /// marker sync to this project.
    private let projectKey: String

    init(projectKey: String) {
        self.projectKey = projectKey
        root = NarrationStorage.activeRoot.appendingPathComponent(Self.safe(projectKey), isDirectory: true)
    }

    /// One-shot relocation of the narration store from its old home in Caches to
    /// its local Application Support root. Same-volume, so the common case is a
    /// single instant rename; a partially-migrated new location is merged
    /// file-by-file (keeping whatever the new location already holds). Safe to
    /// call on every launch — it does nothing once the old directory is gone.
    /// (Lifting the local store into iCloud, when that's enabled, is a separate
    /// step handled by `NarrationStorage.migrate`.)
    static func migrateFromCachesIfNeeded() {
        let fm = FileManager.default
        let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narration", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        let new = NarrationStorage.localRoot
        if fm.fileExists(atPath: new.path) {
            merge(old, into: new, using: fm)
            try? fm.removeItem(at: old)
        } else {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old, to: new)) == nil {
                merge(old, into: new, using: fm)
                try? fm.removeItem(at: old)
            }
        }
    }

    /// Recursively moves every file under `src` to the matching path under `dst`,
    /// never overwriting a file the destination already has. Content-addressed
    /// chunks make same-named files identical, so skipping collisions is safe.
    private static func merge(_ src: URL, into dst: URL, using fm: FileManager) {
        guard let items = try? fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                merge(item, into: target, using: fm)
            } else if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: item, to: target)
            }
        }
    }

    // MARK: - Chunk cache

    func chunkURL(hash: String) -> URL {
        chunkDirectory.appendingPathComponent("\(hash).wav")
    }

    func chunkExists(hash: String) -> Bool {
        NarrationStorage.itemExists(at: chunkURL(hash: hash))
    }

    /// Pulls the given chunks down from iCloud if they're evicted placeholders,
    /// so `loadSamples` can read them when assembling a chapter. No-op locally.
    func ensureChunksDownloaded(hashes: [String]) async {
        await NarrationStorage.ensureDownloaded(hashes.map { chunkURL(hash: $0) })
    }

    func prepareChunkDirectory() throws {
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
    }

    /// Loads an audio file as mono float samples at its native sample rate, for
    /// concatenating cached chunks into a chapter.
    func loadSamples(at url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frameCount { samples[frame] += data[frame] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0..<frameCount { samples[frame] *= scale }
        }
        return (samples, Int(format.sampleRate))
    }

    /// Deletes cached chunks no chapter manifest references any more — orphans
    /// from edited text or a voice the user moved away from.
    func collectGarbageChunks() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: chunkDirectory, includingPropertiesForKeys: nil) else { return }
        let live = liveChunkHashes()
        for file in files where !live.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Assembled chapter audio

    func chapterAudioURL(chapterID: String) throws -> URL {
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
        return chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).wav")
    }

    func existingChapterAudio(chapterID: String) -> URL? {
        let url = chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).wav")
        return NarrationStorage.itemExists(at: url) ? url : nil
    }

    /// Brings a chapter's assembled audio and its small metadata (chunk manifest
    /// and read-along timeline) down from iCloud, so it can be played and read on
    /// a device that didn't generate it. No-op for local storage or already-here
    /// files. Awaited before playback so the "up to date" check reads a real
    /// manifest rather than an evicted placeholder (which would force a needless
    /// re-render).
    func ensureChapterDownloaded(chapterID: String) async {
        let wav = chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).wav")
        await NarrationStorage.ensureDownloaded(
            [wav, manifestURL(chapterID: chapterID), timelineURL(chapterID: chapterID)])
    }

    /// Pulls just a chapter's chunk manifest (a few hundred bytes) down from
    /// iCloud, so `chapterStatus` can read it. Without this, a synced-but-not-yet-
    /// downloaded chapter reads its manifest as a placeholder (nil) and shows as
    /// `.partial` rather than `.ready`. No-op locally or once downloaded.
    func ensureManifestDownloaded(chapterID: String) async {
        await NarrationStorage.ensureDownloaded([manifestURL(chapterID: chapterID)])
    }

    /// How much of a chapter's audio is on disk, for the library indicator.
    enum ChapterAudioStatus: Sendable, Equatable {
        case none      // nothing cached
        case partial   // some chunks rendered, but not assembled / out of date
        case ready     // assembled and matching the current text + voice
    }

    /// `hashes` is the ordered list of the chapter's *audible* chunk hashes for
    /// the current text and voice (`audible.map(\.hash)`).
    func chapterStatus(chapterID: String, hashes: [String]) -> ChapterAudioStatus {
        guard !hashes.isEmpty else { return .none }
        if existingChapterAudio(chapterID: chapterID) != nil,
           loadChunkManifest(chapterID: chapterID) == hashes {
            return .ready
        }
        return hashes.contains(where: chunkExists) ? .partial : .none
    }

    // MARK: - Chunk manifests

    func saveChunkManifest(_ hashes: [String], chapterID: String) throws {
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(hashes)
        try data.write(to: manifestURL(chapterID: chapterID), options: .atomic)
    }

    func loadChunkManifest(chapterID: String) -> [String]? {
        guard let data = try? Data(contentsOf: manifestURL(chapterID: chapterID)) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - Karaoke timelines

    func loadTimeline(chapterID: String) -> ChapterTimeline? {
        guard let data = try? Data(contentsOf: timelineURL(chapterID: chapterID)) else { return nil }
        return try? JSONDecoder().decode(ChapterTimeline.self, from: data)
    }

    func saveTimeline(_ timeline: ChapterTimeline, chapterID: String) throws {
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(timeline)
        try data.write(to: timelineURL(chapterID: chapterID), options: .atomic)
    }

    func hasTimeline(chapterID: String) -> Bool {
        NarrationStorage.itemExists(at: timelineURL(chapterID: chapterID))
    }

    private func timelineURL(chapterID: String) -> URL {
        chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).timeline.json")
    }

    // MARK: - Listener markers

    func loadMarkers(chapterID: String) -> [ChapterMarker] {
        guard let data = try? Data(contentsOf: markersURL(chapterID: chapterID)) else { return [] }
        return (try? JSONDecoder().decode([ChapterMarker].self, from: data)) ?? []
    }

    func saveMarkers(_ markers: [ChapterMarker], chapterID: String) throws {
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(markers)
        try data.write(to: markersURL(chapterID: chapterID), options: .atomic)
    }

    /// Appends a marker and returns the chapter's markers, sorted by time.
    @discardableResult
    func appendMarker(_ marker: ChapterMarker, chapterID: String) -> [ChapterMarker] {
        var markers = loadMarkers(chapterID: chapterID)
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        try? saveMarkers(markers, chapterID: chapterID)
        pushMarkersToCloud(chapterID: chapterID, markers: markers)
        return markers
    }

    private func markersURL(chapterID: String) -> URL {
        chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).markers.json")
    }

    // MARK: - Marker iCloud sync

    /// The book's markers as they stand in iCloud, keyed by chapter id.
    private func cloudMarkerBlob() -> [String: [ChapterMarker]] {
        guard let data = CloudKeyValueStore.data(forKey: CloudKeyValueStore.markersKey(projectKey: projectKey)),
              let blob = try? JSONDecoder().decode([String: [ChapterMarker]].self, from: data) else { return [:] }
        return blob
    }

    private func writeCloudMarkerBlob(_ blob: [String: [ChapterMarker]]) {
        guard let data = try? JSONEncoder().encode(blob) else { return }
        CloudKeyValueStore.set(data, forKey: CloudKeyValueStore.markersKey(projectKey: projectKey))
    }

    private func pushMarkersToCloud(chapterID: String, markers: [ChapterMarker]) {
        var blob = cloudMarkerBlob()
        blob[chapterID] = markers
        writeCloudMarkerBlob(blob)
    }

    /// Folds this book's iCloud markers into the local marker files by union of
    /// marker id (markers are user-created, so nothing is ever dropped), and
    /// pushes any locally-only markers back so every device converges.
    func mergeMarkersFromCloud() {
        let blob = cloudMarkerBlob()
        guard !blob.isEmpty else { return }
        for (chapterID, cloudMarkers) in blob {
            let local = loadMarkers(chapterID: chapterID)
            let merged = Self.union(local, cloudMarkers)
            if merged.count != local.count { try? saveMarkers(merged, chapterID: chapterID) }
            if merged.count != cloudMarkers.count { pushMarkersToCloud(chapterID: chapterID, markers: merged) }
        }
    }

    private static func union(_ a: [ChapterMarker], _ b: [ChapterMarker]) -> [ChapterMarker] {
        var byID: [UUID: ChapterMarker] = [:]
        for marker in a + b { byID[marker.id] = marker }
        return byID.values.sorted { $0.time < $1.time }
    }

    // MARK: - Paths

    private var chunkDirectory: URL { root.appendingPathComponent("chunks", isDirectory: true) }
    private var chapterDirectory: URL { root.appendingPathComponent("chapters", isDirectory: true) }

    private func manifestURL(chapterID: String) -> URL {
        chapterDirectory.appendingPathComponent("\(Self.safe(chapterID)).chunks.json")
    }

    private func liveChunkHashes() -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: chapterDirectory, includingPropertiesForKeys: nil) else { return [] }
        var hashes: Set<String> = []
        for file in files where file.lastPathComponent.hasSuffix(".chunks.json") {
            if let data = try? Data(contentsOf: file),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                hashes.formUnion(list)
            }
        }
        return hashes
    }

    private static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
    }
}

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

    init(projectKey: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches
            .appendingPathComponent("Narration", isDirectory: true)
            .appendingPathComponent(Self.safe(projectKey), isDirectory: true)
    }

    // MARK: - Chunk cache

    func chunkURL(hash: String) -> URL {
        chunkDirectory.appendingPathComponent("\(hash).wav")
    }

    func chunkExists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: chunkURL(hash: hash).path)
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
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

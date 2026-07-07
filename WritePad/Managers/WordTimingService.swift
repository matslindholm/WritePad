import AVFoundation
import Foundation
import os
import Speech

/// Derives a chapter's word-by-word timeline by transcribing its already
/// rendered audio on-device (Apple's Speech framework) and aligning the
/// recognizer's timestamped words onto the script's expected words.
///
/// Works for any language the system can recognize, needs no timing data from
/// the TTS engines, and the caller caches its result next to the audio.
@MainActor
final class WordTimingService {

    enum TimingError: LocalizedError {
        case unauthorized
        case recognizerUnavailable
        case noSpeechRecognized

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Speech recognition isn't allowed. Enable it in Settings › Privacy & Security › Speech Recognition."
            case .recognizerUnavailable:
                return "On-device speech recognition isn't available for this language."
            case .noSpeechRecognized:
                return "Couldn't recognize any speech in this chapter's audio."
            }
        }
    }

    private static let defaultRegion = ["en": "en-US", "de": "de-DE"]
    private static let log = Logger(subsystem: "app.writepad", category: "karaoke")

    /// On-device recognition silently drops the *start* of longer audio (a 45s
    /// window returned nothing for its first 28s, while a 12s clip transcribed
    /// cleanly from the first word). So anything longer is transcribed in short
    /// overlapping windows, then stitched together with offset timestamps.
    private static let chunkSeconds = 12.0
    private static let chunkOverlap = 2.0

    /// Returns the cached timeline if it still matches the audio on disk;
    /// otherwise transcribes and aligns. The caller persists the result.
    func timeline(audioURL: URL, tokens: [ExpectedToken], languageCode: String?,
                  cached: ChapterTimeline?) async throws -> ChapterTimeline {
        let modified = modificationDate(of: audioURL)
        if let cached, cached.version == ChapterTimeline.currentVersion,
           datesMatch(cached.audioModified, modified) {
            return cached
        }

        try await authorize()
        guard let recognizer = recognizer(for: languageCode), recognizer.isAvailable else {
            throw TimingError.recognizerUnavailable
        }
        let totalDuration = duration(of: audioURL)

        let recognized = try await recognize(audioURL: audioURL, using: recognizer)
        guard !recognized.isEmpty else { throw TimingError.noSpeechRecognized }

        Self.log.notice("""
            recognized \(recognized.count, privacy: .public) words over \
            \(totalDuration, format: .fixed(precision: 1), privacy: .public)s, \
            \(tokens.count, privacy: .public) expected tokens
            """)
        Self.log.notice("first recognized: \(Self.summarizeRecognized(recognized.prefix(30)), privacy: .public)")

        // The LCS alignment is a DP over expected × recognized words — off the
        // main actor so it can't stall the UI.
        let words = await Task.detached(priority: .utility) {
            WordAligner.align(expected: tokens, recognized: recognized, totalDuration: totalDuration)
        }.value
        Self.log.notice("aligned first 30: \(Self.summarizeWords(words.prefix(30)), privacy: .public)")
        return ChapterTimeline(audioModified: modified, words: words)
    }

    private static func summarizeRecognized(_ words: some Sequence<RecognizedWord>) -> String {
        words.map { String(format: "%.2f:%@", $0.start, $0.normalized) }.joined(separator: " ")
    }

    private static func summarizeWords(_ words: some Sequence<WordTiming>) -> String {
        words.map { String(format: "%.2f:%@", $0.start, $0.text) }.joined(separator: " ")
    }

    // MARK: - Speech framework

    private func authorize() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TimingError.unauthorized }
    }

    /// Recognizes the whole file directly when short, or in windows when long,
    /// returning words with timestamps absolute to the start of the audio.
    private func recognize(audioURL: URL, using recognizer: SFSpeechRecognizer) async throws -> [RecognizedWord] {
        if duration(of: audioURL) <= Self.chunkSeconds {
            let segments = (try? await recognizeFile(audioURL, using: recognizer)) ?? []
            return words(from: segments, offset: 0)
        }
        return try await recognizeInChunks(audioURL: audioURL, using: recognizer)
    }

    /// Splits the file into short overlapping windows, recognizes each, and
    /// concatenates the words with each window's start time added back. Words
    /// landing in an overlap are de-duplicated by keeping only those whose
    /// timestamp advances past the last one already collected.
    private func recognizeInChunks(audioURL: URL, using recognizer: SFSpeechRecognizer) async throws -> [RecognizedWord] {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let endFrame = file.length
        let windowFrames = AVAudioFrameCount(Self.chunkSeconds * sampleRate)
        let strideFrames = AVAudioFramePosition((Self.chunkSeconds - Self.chunkOverlap) * sampleRate)

        var recognized: [RecognizedWord] = []
        var startFrame: AVAudioFramePosition = 0
        while startFrame < endFrame {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), endFrame - startFrame))
            let buffer = try await Task.detached(priority: .utility) {
                try Self.readWindow(file: file, format: format, startFrame: startFrame, frames: frames)
            }.value
            guard let buffer else { break }

            // A near-silent window makes the recognizer fail with "no speech".
            // That must not discard the words already gathered, so a failed
            // window just contributes nothing.
            let offset = Double(startFrame) / sampleRate
            let segments = (try? await recognizeBuffer(buffer, using: recognizer)) ?? []
            let lastStart = recognized.last?.start ?? -1
            recognized += words(from: segments, offset: offset).filter { $0.start > lastStart + 0.05 }

            startFrame += strideFrames
        }
        return recognized
    }

    private func words(from segments: [SFTranscriptionSegment], offset: Double) -> [RecognizedWord] {
        segments.compactMap { segment in
            let normalized = NarrationScript.normalizeForMatch(segment.substring)
            guard !normalized.isEmpty else { return nil }
            return RecognizedWord(normalized: normalized,
                                  start: offset + segment.timestamp,
                                  end: offset + segment.timestamp + segment.duration)
        }
    }

    /// Reads one recognition window from `file` at `startFrame` into a buffer.
    /// Touches no instance state, so it can run off the main actor.
    private nonisolated static func readWindow(file: AVAudioFile, format: AVAudioFormat,
                                               startFrame: AVAudioFramePosition,
                                               frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frames)
        return buffer
    }

    private func recognizeFile(_ audioURL: URL, using recognizer: SFSpeechRecognizer) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        configure(request, for: recognizer)
        return try await run(request, using: recognizer)
    }

    private func recognizeBuffer(_ buffer: AVAudioPCMBuffer, using recognizer: SFSpeechRecognizer) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(request, for: recognizer)
        request.append(buffer)
        request.endAudio()
        return try await run(request, using: recognizer)
    }

    private func configure(_ request: SFSpeechRecognitionRequest, for recognizer: SFSpeechRecognizer) {
        request.shouldReportPartialResults = false
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    }

    private func run(_ request: SFSpeechRecognitionRequest, using recognizer: SFSpeechRecognizer) async throws -> [SFTranscriptionSegment] {
        let once = ResumeOnce()
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        once.run { continuation.resume(throwing: error) }
                    } else if let result, result.isFinal {
                        once.run { continuation.resume(returning: result.bestTranscription.segments) }
                    }
                }
                taskBox.store(task)
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    private func recognizer(for languageCode: String?) -> SFSpeechRecognizer? {
        guard let code = languageCode, !code.isEmpty else { return SFSpeechRecognizer() }
        let identifier = code.contains("-") ? code : Self.defaultRegion[String(code.prefix(2))] ?? code
        return SFSpeechRecognizer(locale: Locale(identifier: identifier)) ?? SFSpeechRecognizer()
    }

    // MARK: - Audio file metadata

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }

    private func datesMatch(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }

    private func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.fileFormat.sampleRate
        return sampleRate > 0 ? Double(file.length) / sampleRate : 0
    }
}

/// Holds the in-flight recognition task so a task-cancellation handler (which
/// runs on an arbitrary context) can cancel it safely.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func store(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { task.cancel() } else { self.task = task }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// Ensures a continuation is resumed exactly once, even though the recognition
/// callback may fire on an arbitrary queue and more than once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

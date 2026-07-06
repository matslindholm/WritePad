import CryptoKit
import Foundation

/// One generation unit of a chapter. Audio is rendered and cached per chunk, so
/// a single sentence can be regenerated — or reused after a repo update — without
/// redoing the whole chapter.
///
/// - `heading`: the chapter title.
/// - `speech`: a spoken unit — a sentence (Qwen3) or a paragraph (Kokoro).
/// - `sceneBreak`: a thematic break ("* * *"), narrated as silence, not audio.
struct AudioChunk: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading, speech, sceneBreak
    }

    let kind: Kind
    /// Range in the display document (`title` + "\n\n" + `body`), kept for future
    /// highlighting. Not used by assembly.
    let displayRange: NSRange
    /// The exact text sent to the engine (clock fixes applied, emphasis stripped).
    /// Empty for `sceneBreak`.
    let spokenText: String
    /// The voice this chunk's audio was rendered with, so the same sentence
    /// cached under two voices doesn't collide.
    let voiceID: String

    /// Content hash used as the cache filename: identical text + voice always
    /// maps to the same audio. The neural engines ignore `NarrationSettings`, so
    /// only text and voice contribute.
    var hash: String {
        let payload = "\(voiceID)\u{1}\(spokenText)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var isAudible: Bool { kind != .sceneBreak }

    var id: String { "\(displayRange.location)-\(displayRange.length)-\(hash)" }
}

import Foundation

/// A listener's marker dropped while a chapter plays: where it landed in the
/// audio, plus the words being spoken around it (from the read-along timeline)
/// so the marker is legible without playing back to it. Stored per chapter.
struct ChapterMarker: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Seconds from the start of the chapter's audio.
    let time: Double
    /// The words around `time`, taken from the read-along timeline; empty when
    /// no timeline is available yet.
    let context: String
    var createdAt: Date = Date()
}

/// Builds the "words around a point" snippet a marker records, from a chapter's
/// word-by-word timeline.
enum MarkerContext {
    /// Words kept on each side of the spoken word.
    private static let window = 6

    static func text(around time: Double, in words: [WordTiming]) -> String {
        guard !words.isEmpty else { return "" }
        // Last word whose start has passed is the one being spoken.
        let spoken = (words.firstIndex { $0.start > time }.map { $0 - 1 }) ?? (words.count - 1)
        let center = max(0, spoken)
        let lower = max(0, center - window)
        let upper = min(words.count, center + window + 1)
        return words[lower..<upper].map(\.text).joined(separator: " ")
    }
}

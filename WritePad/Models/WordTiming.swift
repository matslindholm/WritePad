import Foundation

/// Markdown emphasis a word carries, shown in the reading view even though the
/// neural engines don't voice it differently.
enum Emphasis: String, Codable, Sendable {
    case none, italic, bold, boldItalic

    var isBold: Bool { self == .bold || self == .boldItalic }
    var isItalic: Bool { self == .italic || self == .boldItalic }

    static func of(bold: Bool, italic: Bool) -> Emphasis {
        switch (bold, italic) {
        case (true, true): return .boldItalic
        case (true, false): return .bold
        case (false, true): return .italic
        case (false, false): return .none
        }
    }
}

/// One displayed word and the slice of audio during which it is spoken.
/// `start`/`end` are seconds from the start of the chapter's audio file.
struct WordTiming: Codable, Equatable, Sendable {
    let text: String          // display token, original casing & punctuation
    let start: Double
    let end: Double
    let paragraphIndex: Int    // groups words into paragraphs for layout
    let emphasis: Emphasis
}

/// A chapter's full word-by-word timeline, cached next to its audio file.
/// `audioModified` is the modification date of the audio it was derived from,
/// so a regenerated chapter recomputes instead of using a stale timeline.
struct ChapterTimeline: Codable, Equatable, Sendable {
    /// Bumped when the alignment algorithm or stored shape changes; an older
    /// cache no longer matches this version and is recomputed. (v2: reject
    /// implausibly early leading anchors — see `WordAligner`.)
    static let currentVersion = 3

    let version: Int
    let audioModified: Date
    let words: [WordTiming]

    init(audioModified: Date, words: [WordTiming]) {
        self.version = Self.currentVersion
        self.audioModified = audioModified
        self.words = words
    }
}

/// A word the narration engine is expected to speak, in spoken order.
/// `normalized` is a lowercased, punctuation-free form used only for matching
/// against the speech recognizer's output; `text` is what we display.
struct ExpectedToken: Equatable, Sendable {
    let text: String
    let normalized: String
    let paragraphIndex: Int
    let emphasis: Emphasis
}

/// A word the speech recognizer reported, with its audio timing.
struct RecognizedWord: Equatable, Sendable {
    let normalized: String
    let start: Double
    let end: Double
}

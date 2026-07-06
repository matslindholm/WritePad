import Foundation

/// The narratable content read from a checked-out book's `Manuscript/` folder.
struct Manuscript: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var chapters: [Chapter]
    var languageCode: String?
}

/// One chapter file, parsed per the Unblock Format (frontmatter + prose).
struct Chapter: Identifiable, Equatable, Sendable {
    /// The frontmatter `id` (e.g. "ch001", "prologue"), unique within a book.
    let id: String
    var title: String
    var order: Int
    var text: String

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

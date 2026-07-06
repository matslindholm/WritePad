import Foundation

enum ChapterReadError: LocalizedError {
    case noManuscript

    var errorDescription: String? {
        switch self {
        case .noManuscript:
            return "This repository has no Manuscript/ folder with chapter files."
        }
    }
}

/// Reads a checked-out book's `Manuscript/` folder into a `Manuscript`,
/// following the Unblock Format: YAML frontmatter per chapter, prologue first,
/// epilogue last, everything else ordered by `order:`.
struct ChapterReader {
    func read(at repoURL: URL, fallbackTitle: String) throws -> Manuscript {
        let config = BookConfig(repoURL: repoURL)
        let manuscriptDir = repoURL.appendingPathComponent("Manuscript", isDirectory: true)
        let files = markdownFiles(in: manuscriptDir)
        guard !files.isEmpty else { throw ChapterReadError.noManuscript }

        let chapters = files
            .compactMap(parseChapter)
            .sorted(by: Self.readingOrder)
        guard !chapters.isEmpty else { throw ChapterReadError.noManuscript }

        return Manuscript(
            id: fallbackTitle,
            title: config.title ?? fallbackTitle,
            chapters: chapters,
            languageCode: config.language)
    }

    private func markdownFiles(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "md" }
    }

    private func parseChapter(_ url: URL) -> Chapter? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (frontmatter, body) = splitFrontmatter(raw)
        let stem = url.deletingPathExtension().lastPathComponent
        let id = frontmatter["id"] ?? Self.canonicalID(for: stem)
        let title = frontmatter["title"] ?? id
        let order = frontmatter["order"].flatMap { Int($0) } ?? Self.sortHint(for: stem)
        let text = stripHeadingPlaceholder(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Chapter(id: id, title: title, order: order, text: text)
    }

    /// Splits a leading `--- … ---` YAML block from the body, returning the
    /// parsed key/values and the remaining prose.
    private func splitFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        var fields: [String: String] = [:]
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let body = lines[(index + 1)...].joined(separator: "\n")
                return (fields, body)
            }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields[key] = value }
            }
        }
        return ([:], text)   // no closing fence — treat as plain content
    }

    /// Drops the Unblock heading placeholder (`# -`) or any leading `# …` line;
    /// the spoken title comes from frontmatter, not the body.
    private func stripHeadingPlaceholder(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Ordering

    /// Prologue always first, epilogue always last, otherwise by `order:` then id.
    private static func readingOrder(_ lhs: Chapter, _ rhs: Chapter) -> Bool {
        let l = positionClass(lhs.id), r = positionClass(rhs.id)
        if l != r { return l < r }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id < rhs.id
    }

    private static func positionClass(_ id: String) -> Int {
        if id == "prologue" { return 0 }
        if id == "epilogue" { return 2 }
        return 1
    }

    private static func canonicalID(for stem: String) -> String {
        if stem.hasSuffix("prologue") { return "prologue" }
        if stem.hasSuffix("epilogue") { return "epilogue" }
        return stem
    }

    private static func sortHint(for stem: String) -> Int {
        let digits = stem.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

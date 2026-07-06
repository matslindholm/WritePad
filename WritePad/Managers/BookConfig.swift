import Foundation

/// Reads the handful of `book.config` values WritePad needs: the book title and
/// its language. `book.config` is plain INI (see the Unblock Format §13); this
/// parses only `[book] title` and `[language] lang`, ignoring everything else.
struct BookConfig {
    let title: String?
    let language: String?

    init(repoURL: URL) {
        let url = repoURL.appendingPathComponent("book.config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            title = nil; language = nil; return
        }
        var section = ""
        var values: [String: String] = [:]   // "section.key" -> value
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { values["\(section).\(key)"] = value }
        }
        title = values["book.title"]
        language = values["language.lang"]
    }
}

import Foundation

/// Builds the text sent to a narration engine: the chapter title, a pause, then
/// the body with scene breaks turned into the same pause. Pauses are marked with
/// a private-use sentinel each engine replaces with silence. Markdown emphasis
/// markers are stripped and soft-wrapped paragraphs reflowed.
enum NarrationScript {
    static let pauseToken = "\u{E000}"
    /// Scene/chapter-break silence, in seconds; read by the engines.
    static let pauseSeconds = 0.6

    static func full(title: String, body: String, languageCode: String? = nil) -> String {
        adjust(title, languageCode) + pauseToken + prepareBody(body, languageCode: languageCode)
    }

    static func isEnglish(_ languageCode: String?) -> Bool {
        languageCode?.lowercased().hasPrefix("en") ?? false
    }

    static func isGerman(_ languageCode: String?) -> Bool {
        languageCode?.lowercased().hasPrefix("de") ?? false
    }

    /// Language-specific clock-time fixes so the engine doesn't voice the colon:
    /// English "8:40" → "8 40"; German "8:40 Uhr" → "8 Uhr 40".
    static func adjust(_ text: String, _ languageCode: String?) -> String {
        if isEnglish(languageCode) {
            return text.replacingOccurrences(
                of: #"(?<!\d)(\d{1,2}):([0-5]\d)(?!\d)"#, with: "$1 $2",
                options: .regularExpression)
        } else if isGerman(languageCode) {
            return text.replacingOccurrences(
                of: #"(?<!\d)(\d{1,2}):([0-5]\d)\s*Uhr\b"#, with: "$1 Uhr $2",
                options: .regularExpression)
        }
        return text
    }

    static func prepareBody(_ body: String, languageCode: String?) -> String {
        reflowParagraphs(stripInlineEmphasis(normalizeSceneBreaks(adjust(body, languageCode))))
    }

    /// Removes `*italic*`, `**bold**`, and boundary `_`/`__` emphasis markers so
    /// the engine narrates the words, not the asterisks (`snake_case` survives).
    static func stripInlineEmphasis(_ text: String) -> String {
        var result = text
        for pattern in [
            #"\*\*(.+?)\*\*"#,
            #"\*(.+?)\*"#,
            #"(?<![\p{L}\p{N}])__(.+?)__(?![\p{L}\p{N}])"#,
            #"(?<![\p{L}\p{N}])_(.+?)_(?![\p{L}\p{N}])"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    /// Turns a Markdown thematic break (three or more of `*`, `-`, or `_`) into
    /// the pause token, so both "* * *" and "---" read as a scene break.
    static func normalizeSceneBreaks(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?m)^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#,
            with: pauseToken, options: .regularExpression)
    }

    /// A single newline within a paragraph is a soft wrap → space; only a blank
    /// line starts a new paragraph.
    static func reflowParagraphs(_ text: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n")
    }
}

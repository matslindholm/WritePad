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

    // MARK: - Karaoke tokens

    /// The exact word sequence the engine speaks, in order, for the reading
    /// view. Words keep their original text (e.g. "8:40" — the audio's language
    /// fixes are deliberately not applied) but each carries the `Emphasis` it
    /// was wrapped in. Each pause or paragraph break starts a new
    /// `paragraphIndex`; the title is paragraph 0.
    static func tokens(title: String, body: String) -> [ExpectedToken] {
        let prepared = title + pauseToken + reflowParagraphs(normalizeSceneBreaks(body))
        let separators = CharacterSet(charactersIn: pauseToken + "\n")
        var tokens: [ExpectedToken] = []
        var paragraph = -1
        for (index, segment) in prepared.components(separatedBy: separators).enumerated() {
            let words = scanEmphasis(segment)
            guard !words.isEmpty else { continue }
            paragraph = index == 0 ? 0 : max(paragraph + 1, 1)
            for word in words {
                tokens.append(ExpectedToken(text: word.text,
                                            normalized: normalizeForMatch(word.text),
                                            paragraphIndex: paragraph,
                                            emphasis: word.emphasis))
            }
        }
        return tokens
    }

    /// Splits a segment into words, stripping `*`/`**` (and boundary `_`/`__`)
    /// emphasis markers while tagging each word with the emphasis in effect.
    static func scanEmphasis(_ segment: String) -> [(text: String, emphasis: Emphasis)] {
        var words: [(String, Emphasis)] = []
        var current = ""
        var bold = false, italic = false
        var wordBold = false, wordItalic = false
        let chars = Array(segment)

        func flush() {
            if !current.isEmpty {
                words.append((current, Emphasis.of(bold: wordBold, italic: wordItalic)))
                current = ""
            }
        }
        func boundary(_ char: Character?) -> Bool {
            guard let char else { return true }
            return !(char.isLetter || char.isNumber)
        }

        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { bold.toggle(); i += 2 }
                else { italic.toggle(); i += 1 }
                continue
            }
            if char == "_" {
                let double = i + 1 < chars.count && chars[i + 1] == "_"
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + (double ? 2 : 1) < chars.count ? chars[i + (double ? 2 : 1)] : nil
                if boundary(prev) != boundary(next) {
                    if double { bold.toggle(); i += 2 } else { italic.toggle(); i += 1 }
                    continue
                }
            }
            if char.isWhitespace { flush(); i += 1; continue }
            if current.isEmpty { wordBold = bold; wordItalic = italic }
            current.append(char)
            i += 1
        }
        flush()
        return words
    }

    /// Lowercased, alphanumerics-only form for fuzzy matching against the
    /// speech recognizer (which drops punctuation and varies casing).
    static func normalizeForMatch(_ word: String) -> String {
        String(String.UnicodeScalarView(
            word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
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

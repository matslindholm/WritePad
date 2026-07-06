import Foundation

/// Splits a chapter into ordered `AudioChunk`s whose `displayRange`s index into
/// the display document (`title` + "\n\n" + `body`).
///
/// Granularity follows the engine's natural unit: Qwen3 renders one sentence at
/// a time (so a chunk is a sentence), while Kokoro renders a whole paragraph at
/// once (so a chunk is a paragraph).
enum ChapterChunker {
    /// A thematic break — three or more of the same marker on a line.
    private static let sceneBreakPattern = #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#
    /// One or more blank lines separate paragraphs.
    private static let paragraphSeparator = #"\n[ \t]*\n[ \t\r\n]*"#
    /// Sentence boundary — same as `Qwen3NarrationEngine.sentences`.
    private static let sentenceSeparator = #"(?<=[.!?])\s+"#

    static func displayDocument(title: String, body: String) -> String {
        title.isEmpty ? body : title + "\n\n" + body
    }

    static func chunks(title: String, body: String, voice: NarrationVoice, languageCode: String?) -> [AudioChunk] {
        var chunks: [AudioChunk] = []

        let titleNS = title as NSString
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let spoken = NarrationScript.adjust(title, languageCode)
            chunks.append(AudioChunk(kind: .heading, displayRange: NSRange(location: 0, length: titleNS.length),
                                     spokenText: spoken, voiceID: voice.id))
        }

        let bodyOffset = title.isEmpty ? 0 : titleNS.length + 2  // length of "\n\n"
        let bodyNS = body as NSString
        let fullBody = NSRange(location: 0, length: bodyNS.length)

        var cursor = 0
        for breakRange in matches(of: sceneBreakPattern, in: bodyNS, range: fullBody, perLine: true) {
            appendSpeech(in: bodyNS, range: NSRange(location: cursor, length: breakRange.location - cursor),
                         voice: voice, languageCode: languageCode, bodyOffset: bodyOffset, into: &chunks)
            chunks.append(AudioChunk(kind: .sceneBreak, displayRange: shift(breakRange, by: bodyOffset),
                                     spokenText: "", voiceID: voice.id))
            cursor = breakRange.location + breakRange.length
        }
        appendSpeech(in: bodyNS, range: NSRange(location: cursor, length: bodyNS.length - cursor),
                     voice: voice, languageCode: languageCode, bodyOffset: bodyOffset, into: &chunks)

        return chunks
    }

    // MARK: - Decomposition

    private static func appendSpeech(in bodyNS: NSString, range block: NSRange, voice: NarrationVoice,
                                     languageCode: String?, bodyOffset: Int, into chunks: inout [AudioChunk]) {
        guard block.length > 0 else { return }
        for paragraph in splitRanges(in: bodyNS, range: block, separator: paragraphSeparator) {
            guard let paragraph = trimmed(paragraph, in: bodyNS) else { continue }
            let unitRanges = voice.engine == .qwen3
                ? splitRanges(in: bodyNS, range: paragraph, separator: sentenceSeparator)
                : [paragraph]
            for unit in unitRanges {
                guard let unit = trimmed(unit, in: bodyNS) else { continue }
                let original = bodyNS.substring(with: unit)
                let spoken = NarrationScript.prepareBody(original, languageCode: languageCode)
                guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                chunks.append(AudioChunk(kind: .speech, displayRange: shift(unit, by: bodyOffset),
                                         spokenText: spoken, voiceID: voice.id))
            }
        }
    }

    // MARK: - Range helpers

    /// Subranges of `range` left after removing every match of `pattern`.
    private static func splitRanges(in ns: NSString, range: NSRange, separator pattern: String) -> [NSRange] {
        var pieces: [NSRange] = []
        var cursor = range.location
        let end = range.location + range.length
        for match in matches(of: pattern, in: ns, range: range, perLine: false) {
            if match.location > cursor {
                pieces.append(NSRange(location: cursor, length: match.location - cursor))
            }
            cursor = match.location + match.length
        }
        if cursor < end { pieces.append(NSRange(location: cursor, length: end - cursor)) }
        return pieces
    }

    private static func matches(of pattern: String, in ns: NSString, range: NSRange, perLine: Bool) -> [NSRange] {
        let options: NSRegularExpression.Options = perLine ? [.anchorsMatchLines] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: ns as String, range: range).map(\.range)
    }

    /// Trims leading/trailing whitespace from a range, or nil if it collapses.
    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange? {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        var end = range.location + range.length
        while start < end, let scalar = ns.substring(with: NSRange(location: start, length: 1)).unicodeScalars.first,
              whitespace.contains(scalar) { start += 1 }
        while end > start, let scalar = ns.substring(with: NSRange(location: end - 1, length: 1)).unicodeScalars.first,
              whitespace.contains(scalar) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func shift(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}

import Foundation

/// User-configurable pronunciation tuning: a list of text substitutions applied
/// to a chapter's spoken text before synthesis (e.g. read "18:25" as "18 Uhr
/// 25", or "IBM" as "Eye Bee Emm"), plus reusable sample phrases for auditioning
/// them. Persisted as JSON by `PronunciationSettings`.
struct PronunciationRules: Codable, Equatable, Sendable {
    var substitutions: [TextSubstitution]
    var sampleSentences: [SampleSentence]

    static let `default` = PronunciationRules(
        substitutions: [],
        sampleSentences: defaultSampleSentences)

    static let defaultSampleSentences: [SampleSentence] = [
        SampleSentence(text: "Meet me at 18:25 — ask for IBM.", language: .english),
        SampleSentence(text: "Wir treffen uns um 18:25 Uhr — frag nach IBM.", language: .german),
    ]

    init(substitutions: [TextSubstitution], sampleSentences: [SampleSentence]) {
        self.substitutions = substitutions
        self.sampleSentences = sampleSentences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        substitutions = try container.decode([TextSubstitution].self, forKey: .substitutions)
        // Rules stored before sample sentences existed seed the examples, so the
        // tester isn't empty after upgrading.
        sampleSentences = try container.decodeIfPresent([SampleSentence].self, forKey: .sampleSentences)
            ?? Self.defaultSampleSentences
    }
}

/// A phrase kept in the pronunciation panel for auditioning rules, tagged with
/// the narration language it's meant to exercise.
struct SampleSentence: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String = ""
    var language: RuleLanguage = .any
}

/// Which narration language a rule applies to.
enum RuleLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, english, german

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any language"
        case .english: return "English"
        case .german: return "German"
        }
    }

    /// Whether this scope covers the given narration language code (e.g. "en-US").
    func matches(_ languageCode: String?) -> Bool {
        switch self {
        case .any: return true
        case .english: return languageCode?.lowercased().hasPrefix("en") ?? false
        case .german: return languageCode?.lowercased().hasPrefix("de") ?? false
        }
    }
}

/// A single "read X as Y" rule. `pattern` is matched literally unless `isRegex`
/// is set, in which case it's an ICU regular expression and `replacement` may
/// use `$1`-style capture references.
struct TextSubstitution: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var pattern: String = ""
    var replacement: String = ""
    var isRegex: Bool = false
    var language: RuleLanguage = .any
    var isEnabled: Bool = true

    /// Applies the rule to `text`, or returns it unchanged when the rule is
    /// disabled or has an empty pattern.
    func apply(to text: String) -> String {
        guard isEnabled, !pattern.isEmpty else { return text }
        let options: String.CompareOptions = isRegex ? .regularExpression : []
        return text.replacingOccurrences(of: pattern, with: replacement, options: options)
    }
}

/// The portable form of the pronunciation panel — the user's substitution rules
/// and their test samples — for exporting to and importing from a JSON file.
struct PronunciationExchange: Codable, Equatable, Sendable {
    var version = 1
    var substitutions: [TextSubstitution]
    var sampleSentences: [SampleSentence]
}

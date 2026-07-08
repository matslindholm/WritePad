import Foundation
import Observation

/// Owns the user's pronunciation `PronunciationRules` and persists them. The
/// enabled, language-matching substitutions are applied to a chapter's spoken
/// text before synthesis (see `NarrationScript`/`ChapterChunker`) — never to the
/// displayed text, so the reading view still shows the words as written.
@MainActor
@Observable
final class PronunciationSettings {
    var rules: PronunciationRules {
        didSet { persist() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "pronunciationRules"
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(PronunciationRules.self, from: data) {
            rules = decoded
        } else {
            rules = .default
        }
        // Fold in anything already synced from another device. `didSet` doesn't
        // fire during init, so persist the merged result explicitly.
        if mergeFromCloud() { persist() }
        cloudObserver = CloudKeyValueStore.observeExternalChanges { [weak self] in
            Task { @MainActor in self?.mergeFromCloud() }
        }
    }

    /// The enabled substitutions that apply to a narration language, in order.
    func substitutions(for languageCode: String?) -> [TextSubstitution] {
        rules.substitutions.filter { $0.isEnabled && $0.language.matches(languageCode) }
    }

    func addSubstitution(language: RuleLanguage = .any) {
        rules.substitutions.append(TextSubstitution(language: language))
    }

    func removeSubstitution(id: TextSubstitution.ID) {
        rules.substitutions.removeAll { $0.id == id }
    }

    @discardableResult
    func addSampleSentence(language: RuleLanguage = .any) -> SampleSentence.ID {
        let sample = SampleSentence(language: language)
        rules.sampleSentences.append(sample)
        return sample.id
    }

    func removeSampleSentence(id: SampleSentence.ID) {
        rules.sampleSentences.removeAll { $0.id == id }
    }

    /// The rules and samples as pretty-printed JSON for export.
    func exportData() throws -> Data {
        let exchange = PronunciationExchange(substitutions: rules.substitutions,
                                             sampleSentences: rules.sampleSentences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exchange)
    }

    /// Merges imported rules and samples into the current set without replacing
    /// anything: entries that already exist (matched by content) are skipped, and
    /// each newly added entry gets a fresh id. Returns how many of each were added.
    @discardableResult
    func merge(_ exchange: PronunciationExchange) -> (rules: Int, samples: Int) {
        var merged = rules
        var addedRules = 0
        for imported in exchange.substitutions {
            let duplicate = merged.substitutions.contains {
                $0.pattern == imported.pattern && $0.replacement == imported.replacement
                    && $0.isRegex == imported.isRegex && $0.language == imported.language
            }
            guard !duplicate else { continue }
            var copy = imported
            copy.id = UUID()
            merged.substitutions.append(copy)
            addedRules += 1
        }
        var addedSamples = 0
        for imported in exchange.sampleSentences {
            let duplicate = merged.sampleSentences.contains {
                $0.text == imported.text && $0.language == imported.language
            }
            guard !duplicate else { continue }
            var copy = imported
            copy.id = UUID()
            merged.sampleSentences.append(copy)
            addedSamples += 1
        }
        rules = merged
        return (addedRules, addedSamples)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
        pushToCloud()
    }

    // MARK: - iCloud sync

    /// Mirrors the current rules to iCloud key–value storage. A no-op when iCloud
    /// is unavailable, so nothing changes offline.
    private func pushToCloud() {
        let exchange = PronunciationExchange(substitutions: rules.substitutions,
                                             sampleSentences: rules.sampleSentences)
        if let data = try? JSONEncoder().encode(exchange) {
            CloudKeyValueStore.set(data, forKey: CloudKeyValueStore.pronunciationKey)
        }
    }

    /// Merges rules synced from another device into the local set, additively and
    /// deduped by content (same policy as importing). Returns whether anything
    /// was added. Outside `init`, `merge` re-persists via `didSet`, which pushes
    /// the merged set back so every device converges.
    @discardableResult
    private func mergeFromCloud() -> Bool {
        guard let data = CloudKeyValueStore.data(forKey: CloudKeyValueStore.pronunciationKey),
              let exchange = try? JSONDecoder().decode(PronunciationExchange.self, from: data) else { return false }
        let added = merge(exchange)
        return added.rules > 0 || added.samples > 0
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The macOS pronunciation editor, styled after abm's Settings panel: a language
/// filter, a table of "read X as Y" substitution rules, an add/import/export
/// bar, and a sample tester at the bottom. iPad uses `PronunciationSettingsView`
/// (a grouped form) instead, which suits touch and the narrower sheet.
struct PronunciationPanel: View {
    @Environment(PronunciationSettings.self) private var pronunciation

    /// Language filter for the whole panel; universal (`.any`) rules and samples
    /// stay visible under every setting.
    @AppStorage("pronunciationLanguageFilter") private var filter: RuleLanguage = .any
    @State private var alert: String?

    var body: some View {
        @Bindable var pronunciation = pronunciation
        VStack(spacing: 0) {
            filterBar
            Divider()
            ruleList(pronunciation)
            Divider()
            actionBar(pronunciation)
            Divider()
            SampleTester(filter: filter)
        }
        .alert("Pronunciation", isPresented: Binding(
            get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert ?? "")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("Language").font(.caption).foregroundStyle(.secondary)
            Picker("Language", selection: $filter) {
                ForEach(RuleLanguage.allCases) { Text($0.filterLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func actionBar(_ pronunciation: PronunciationSettings) -> some View {
        HStack {
            Button { pronunciation.addSubstitution(language: filter) } label: {
                Label("Add Rule", systemImage: "plus")
            }
            Spacer()
            Button("Import…", action: { importRules(pronunciation) })
                .help("Import rules and samples from a JSON file, merging them with the current ones.")
            Button("Export…", action: { exportRules(pronunciation) })
                .help("Export all rules and samples to a JSON file.")
                .disabled(pronunciation.rules.substitutions.isEmpty
                          && pronunciation.rules.sampleSentences.isEmpty)
        }
        .padding(8)
    }

    @ViewBuilder
    private func ruleList(_ pronunciation: PronunciationSettings) -> some View {
        @Bindable var pronunciation = pronunciation
        let visible = pronunciation.rules.substitutions.filter { filter.shows($0.language) }
        if pronunciation.rules.substitutions.isEmpty {
            ContentUnavailableView {
                Label("No Rules", systemImage: "character.bubble")
            } description: {
                Text("Add a rule to change how text is read aloud, e.g. read “18:25” as “18 Uhr 25”, or “IBM” as “Eye Bee Emm”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("No \(filter.label) Rules", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No rules apply to \(filter.label). Add one, or switch the filter to “All”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RuleHeader()
                .padding(.horizontal)
                .padding(.top, 8)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($pronunciation.rules.substitutions) { $rule in
                        if filter.shows(rule.language) {
                            RuleRow(rule: $rule) { pronunciation.removeSubstitution(id: rule.id) }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func exportRules(_ pronunciation: PronunciationSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Pronunciation.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pronunciation.exportData().write(to: url)
        } catch {
            alert = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importRules(_ pronunciation: PronunciationSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let exchange = try JSONDecoder().decode(PronunciationExchange.self, from: data)
            let added = pronunciation.merge(exchange)
            alert = "Imported \(added.rules) rule\(added.rules == 1 ? "" : "s") "
                + "and \(added.samples) sample\(added.samples == 1 ? "" : "s"). "
                + "Duplicates were skipped."
        } catch {
            alert = "Couldn't import: \(error.localizedDescription)"
        }
    }
}

/// Auditions the current rules: pick a language-tagged sample from a dropdown
/// (or add one), choose a voice, then synthesize it with the same substitutions
/// real narration uses. Honors the panel's language filter.
private struct SampleTester: View {
    let filter: RuleLanguage
    @Environment(PronunciationSettings.self) private var pronunciation
    @Environment(NarrationCoordinator.self) private var narration

    @State private var player = ReadingPlayer()
    @AppStorage("pronunciationSampleVoiceID") private var voiceID = ""
    @State private var voices: [NarrationVoice] = []
    @State private var chosenID: SampleSentence.ID?
    /// The sample currently rendering or playing, so only its cell shows Stop.
    @State private var activeSampleID: SampleSentence.ID?
    @State private var isRendering = false
    @State private var error: String?

    private var samples: [SampleSentence] {
        pronunciation.rules.sampleSentences.filter { filter.shows($0.language) }
    }

    private var selectedID: SampleSentence.ID? {
        if let chosenID, samples.contains(where: { $0.id == chosenID }) { return chosenID }
        return samples.first?.id
    }

    private var selectedSample: SampleSentence? {
        pronunciation.rules.sampleSentences.first { $0.id == selectedID }
    }

    private var selectedVoice: NarrationVoice? {
        voices.first { $0.id == voiceID } ?? voices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Test").font(.headline)
                Spacer()
                Picker("Voice", selection: $voiceID) {
                    ForEach(voices) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(voices.isEmpty)
            }

            HStack(spacing: RuleColumn.spacing) {
                Picker("Sample", selection: sampleSelection) {
                    if samples.isEmpty {
                        Text("No samples").tag(SampleSentence.ID?.none)
                    }
                    ForEach(samples) { Text(label(for: $0)).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .disabled(samples.isEmpty)
                Button(action: addSample) {
                    Image(systemName: "plus")
                }
                .help("Add a sample sentence")
            }

            if let sample = selectedSample, let id = selectedID {
                HStack(spacing: RuleColumn.spacing) {
                    playButton(for: sample)
                    TextField("Sample text", text: textBinding(id))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { play(sample) }
                    Picker("Language", selection: languageBinding(id)) {
                        ForEach(RuleLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: RuleColumn.language)
                    Button(role: .destructive) { deleteSample(id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: RuleColumn.delete)
                    .help("Delete this sample")
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if voices.isEmpty {
                Text("Voices are still loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task(id: filter) { await loadVoices() }
        .onChange(of: player.isPlaying) { _, playing in
            if !playing, !isRendering { activeSampleID = nil }
        }
        .onDisappear { player.stop() }
    }

    /// Voices for the filtered language; the All filter offers every voice.
    private func loadVoices() async {
        switch filter {
        case .german:
            voices = await narration.voices(for: "de")
        case .english:
            voices = await narration.voices(for: "en")
        case .any:
            voices = await narration.voices(for: "en") + narration.voices(for: "de")
        }
        if !voices.contains(where: { $0.id == voiceID }) {
            voiceID = voices.first?.id ?? ""
        }
    }

    /// The voice to audition a sample with: prefer the picked voice when it fits
    /// the sample's language, otherwise the first voice for that language.
    private func voice(for sample: SampleSentence) -> NarrationVoice? {
        if sample.language == .any { return selectedVoice }
        if let picked = selectedVoice, sample.language.matches(picked.language) { return picked }
        return voices.first { sample.language.matches($0.language) } ?? selectedVoice
    }

    /// Dropdown label: the sample text (or a placeholder), prefixed with its
    /// language when the panel isn't already filtered to one.
    private func label(for sample: SampleSentence) -> String {
        let trimmed = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "(new sample)" : trimmed
        if filter == .any, sample.language != .any {
            return "\(sample.language.label): \(text)"
        }
        return text
    }

    private var sampleSelection: Binding<SampleSentence.ID?> {
        Binding(get: { selectedID }, set: { chosenID = $0 })
    }

    private func textBinding(_ id: SampleSentence.ID) -> Binding<String> {
        Binding(
            get: { pronunciation.rules.sampleSentences.first { $0.id == id }?.text ?? "" },
            set: { newText in
                if let index = pronunciation.rules.sampleSentences.firstIndex(where: { $0.id == id }) {
                    pronunciation.rules.sampleSentences[index].text = newText
                }
            })
    }

    private func languageBinding(_ id: SampleSentence.ID) -> Binding<RuleLanguage> {
        Binding(
            get: { pronunciation.rules.sampleSentences.first { $0.id == id }?.language ?? .any },
            set: { newLanguage in
                if let index = pronunciation.rules.sampleSentences.firstIndex(where: { $0.id == id }) {
                    pronunciation.rules.sampleSentences[index].language = newLanguage
                }
            })
    }

    @ViewBuilder
    private func playButton(for sample: SampleSentence) -> some View {
        if isRendering, activeSampleID == sample.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: RuleColumn.toggle)
        } else if player.isPlaying, activeSampleID == sample.id {
            Button { stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
                .frame(width: RuleColumn.toggle)
                .help("Stop")
        } else {
            Button { play(sample) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .frame(width: RuleColumn.toggle)
                .disabled(isRendering || voice(for: sample) == nil
                          || sample.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Play this sample with the current rules applied")
        }
    }

    private func addSample() {
        chosenID = pronunciation.addSampleSentence(language: filter)
    }

    private func deleteSample(_ id: SampleSentence.ID) {
        pronunciation.removeSampleSentence(id: id)
        chosenID = samples.first?.id
    }

    private func play(_ sample: SampleSentence) {
        guard let voice = voice(for: sample) else { return }
        error = nil
        activeSampleID = sample.id
        isRendering = true
        Task {
            do {
                let url = try await narration.renderSample(sample.text, voice: voice)
                isRendering = false
                guard let url else { activeSampleID = nil; return }
                try player.load(url: url)
                player.play()
            } catch {
                isRendering = false
                activeSampleID = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func stop() {
        player.stop()
        activeSampleID = nil
    }
}

/// Shared column widths so the header labels line up with each rule's cells.
private enum RuleColumn {
    static let toggle: CGFloat = 28
    static let language: CGFloat = 120
    static let regex: CGFloat = 52
    static let delete: CGFloat = 24
    static let spacing: CGFloat = 8
}

private struct RuleHeader: View {
    var body: some View {
        HStack(spacing: RuleColumn.spacing) {
            Text("On").frame(width: RuleColumn.toggle)
            Text("Input").frame(maxWidth: .infinity, alignment: .leading)
            Text("Output").frame(maxWidth: .infinity, alignment: .leading)
            Text("Language").frame(width: RuleColumn.language, alignment: .leading)
            Text("Regex").frame(width: RuleColumn.regex)
            Spacer().frame(width: RuleColumn.delete)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RuleRow: View {
    @Binding var rule: TextSubstitution
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: RuleColumn.spacing) {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: RuleColumn.toggle)
                .help("Enable this rule")
            TextField("Read this…", text: $rule.pattern)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            TextField("…as this", text: $rule.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Picker("Language", selection: $rule.language) {
                ForEach(RuleLanguage.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: RuleColumn.language)
            Toggle("", isOn: $rule.isRegex)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: RuleColumn.regex)
                .help("Match the pattern as an ICU regular expression; the replacement may use $1, $2… capture groups.")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: RuleColumn.delete)
            .help("Delete this rule")
        }
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

private extension RuleLanguage {
    /// Short label for the segmented filter (`.any` reads as "All" there).
    var filterLabel: String {
        switch self {
        case .any: return "All"
        case .english: return "English"
        case .german: return "German"
        }
    }

    /// Whether this filter shows an entry tagged `language`. Universal (`.any`)
    /// entries are always visible, and the All filter shows everything.
    func shows(_ language: RuleLanguage) -> Bool {
        self == .any || language == .any || language == self
    }
}
#endif

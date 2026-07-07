import SwiftUI
import UniformTypeIdentifiers

/// Editor for the user's pronunciation rules: "read X as Y" substitutions
/// applied to a chapter's spoken text before synthesis (never to the displayed
/// text), with sample phrases to audition them and JSON import/export.
struct PronunciationSettingsView: View {
    @Environment(PronunciationSettings.self) private var pronunciation
    @Environment(NarrationCoordinator.self) private var narration

    @State private var player = ReadingPlayer()
    @State private var auditioning: SampleSentence.ID?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: JSONDocument?
    @State private var message: String?

    var body: some View {
        @Bindable var pronunciation = pronunciation
        Form {
            Section {
                ForEach($pronunciation.rules.substitutions) { $rule in
                    SubstitutionRow(rule: $rule)
                        .swipeActions {
                            Button(role: .destructive) {
                                pronunciation.removeSubstitution(id: rule.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                Button { pronunciation.addSubstitution() } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            } header: {
                Text("Substitutions")
            } footer: {
                Text("The pattern is read as the replacement before synthesis; the displayed text is unchanged. Turn on Regex for ICU pattern matching with $1 capture references.")
            }

            Section {
                ForEach($pronunciation.rules.sampleSentences) { $sample in
                    SampleRow(sample: $sample,
                              isAuditioning: auditioning == sample.id,
                              onPlay: { audition(sample) })
                        .swipeActions {
                            Button(role: .destructive) {
                                pronunciation.removeSampleSentence(id: sample.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                Button { pronunciation.addSampleSentence() } label: {
                    Label("Add Sample", systemImage: "plus")
                }
            } header: {
                Text("Try It")
            } footer: {
                Text("Play a sample to hear the current rules applied. The first audition may download the voice.")
            }

            if let message {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Pronunciation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { beginExport() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "pronunciation") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Actions

    private func audition(_ sample: SampleSentence) {
        message = nil
        auditioning = sample.id
        Task {
            defer { auditioning = nil }
            do {
                guard let url = try await narration.renderSample(
                    sample.text, languageCode: Self.code(for: sample.language)) else {
                    message = "Nothing to speak in this sample."
                    return
                }
                try player.load(url: url)
                player.play()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func beginExport() {
        do {
            exportDocument = JSONDocument(data: try pronunciation.exportData())
            showExporter = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let exchange = try JSONDecoder().decode(PronunciationExchange.self, from: data)
                let added = pronunciation.merge(exchange)
                message = "Imported \(added.rules) rule(s) and \(added.samples) sample(s)."
            } catch {
                message = "Couldn't import: \(error.localizedDescription)"
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    /// Audition language code for a rule scope; `.any` auditions in English.
    private static func code(for language: RuleLanguage) -> String? {
        switch language {
        case .any, .english: return "en"
        case .german: return "de"
        }
    }
}

// MARK: - Rows

private struct SubstitutionRow: View {
    @Binding var rule: TextSubstitution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Pattern", text: $rule.pattern)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Replacement", text: $rule.replacement)
            }
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            HStack(spacing: 12) {
                Toggle("Enabled", isOn: $rule.isEnabled)
                    .labelsHidden()
                Picker("Language", selection: $rule.language) {
                    ForEach(RuleLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                Toggle(isOn: $rule.isRegex) { Text("Regex") }
                    .toggleStyle(.button)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .opacity(rule.isEnabled ? 1 : 0.5)
    }
}

private struct SampleRow: View {
    @Binding var sample: SampleSentence
    let isAuditioning: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Sample sentence", text: $sample.text)
                Picker("Language", selection: $sample.language) {
                    ForEach(RuleLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .labelsHidden()
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: isAuditioning ? "waveform" : "play.circle")
                    .font(.title2)
                    .symbolEffect(.variableColor, isActive: isAuditioning)
            }
            .buttonStyle(.borderless)
            .disabled(isAuditioning)
        }
    }
}

/// Minimal JSON file wrapper for the pronunciation exporter.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

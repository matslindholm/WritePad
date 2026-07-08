import SwiftUI

/// The GitHub token field and its removal control. Shared by the iOS settings
/// sheet and the macOS Settings window's General tab; editing mutates the bound
/// `token`, and the owner decides when to persist it.
struct GitHubTokenSettings: View {
    @Environment(AppSettings.self) private var settings
    @Binding var token: String

    var body: some View {
        Section {
            SecureField("ghp_…", text: $token)
                .noAutocapitalization()
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("GitHub Access Token")
        } footer: {
            Text("A fine-grained or classic personal access token with repository read access. Stored securely in the Keychain, never synced.")
        }

        if settings.hasToken {
            Section {
                Button("Remove Token", role: .destructive) {
                    token = ""
                    settings.githubToken = ""
                }
            }
        }
    }
}

/// Toggle for storing generated audio in iCloud, with live migration status.
/// Shared by the iOS settings sheet and the macOS General tab.
struct AudioStorageSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Toggle("Store Audio in iCloud", isOn: Binding(
                get: { settings.syncAudioToICloud },
                set: { on in Task { await settings.setSyncAudioToICloud(on) } }))
                .disabled(settings.iCloudMigration == .running)

            if settings.iCloudMigration == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(settings.syncAudioToICloud ? "Bringing audio back to this device…"
                                                    : "Moving audio to iCloud…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Audio Storage")
        } footer: {
            if case .failed(let message) = settings.iCloudMigration {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Keep generated narration in iCloud so it — and your markers — follow you to your other devices. Audio can be large and uses your iCloud storage. Manuscripts always sync from GitHub, so they're never stored here.")
            }
        }
    }
}

#if os(iOS)
/// GitHub token entry presented as a modal sheet on iPad, with an explicit
/// Save so a mistyped token isn't committed.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""

    var body: some View {
        NavigationStack {
            Form {
                GitHubTokenSettings(token: $token)

                AudioStorageSettings()

                Section {
                    NavigationLink {
                        PronunciationSettingsView()
                    } label: {
                        Label("Pronunciation", systemImage: "character.bubble")
                    }
                } footer: {
                    Text("Teach the narrator how to say specific words, numbers, or abbreviations.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.githubToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
            .onAppear { token = settings.githubToken }
        }
    }
}
#endif

#if os(macOS)
/// The macOS Settings window (⌘,): a tabbed preferences pane. The token commits
/// as the field is edited, matching the live-apply convention of Mac settings.
struct MacSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var token: String = ""

    var body: some View {
        TabView {
            Form {
                GitHubTokenSettings(token: $token)
                AudioStorageSettings()
            }
            .formStyle(.grouped)
            .onAppear { token = settings.githubToken }
            .onChange(of: token) { commit() }
            .tabItem { Label("General", systemImage: "gearshape") }

            PronunciationPanel()
                .tabItem { Label("Pronunciation", systemImage: "character.bubble") }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 620)
    }

    private func commit() {
        settings.githubToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

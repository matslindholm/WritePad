import SwiftUI

/// GitHub access-token entry. The token is stored in the Keychain and used for
/// both listing repositories and cloning private ones.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ghp_…", text: $token)
                        .textInputAutocapitalization(.never)
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

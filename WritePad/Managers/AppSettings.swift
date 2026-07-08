import Foundation
import Observation

/// App-wide settings. The GitHub token is Keychain-backed; the repos root is
/// a fixed folder under Application Support that holds every checked-out clone.
@Observable
final class AppSettings {
    private static let tokenAccount = "github-token"

    var githubToken: String {
        didSet { Keychain.set(githubToken.isEmpty ? nil : githubToken, for: Self.tokenAccount) }
    }

    var hasToken: Bool { !githubToken.isEmpty }

    /// Whether generated audio is stored in iCloud (opt-in). Mirrored into
    /// UserDefaults under the key `NarrationStorage` reads, so the active
    /// storage root resolves the same off the main actor. Flip it via
    /// `setSyncAudioToICloud` — assigning directly would skip the data move.
    private(set) var syncAudioToICloud: Bool {
        didSet { UserDefaults.standard.set(syncAudioToICloud, forKey: NarrationStorage.iCloudEnabledKey) }
    }

    /// Progress of an in-flight storage move, for the settings UI.
    enum ICloudMigration: Equatable { case idle, running, failed(String) }
    private(set) var iCloudMigration: ICloudMigration = .idle

    init() {
        githubToken = Keychain.string(for: Self.tokenAccount) ?? ""
        syncAudioToICloud = UserDefaults.standard.bool(forKey: NarrationStorage.iCloudEnabledKey)
    }

    /// Turns iCloud audio storage on or off, moving the narration cache to match.
    /// The flag is committed only after the move succeeds, so a failed enable
    /// (e.g. iCloud not signed in) leaves everything local and untouched.
    @MainActor
    func setSyncAudioToICloud(_ on: Bool) async {
        guard on != syncAudioToICloud, iCloudMigration != .running else { return }
        iCloudMigration = .running
        do {
            try await NarrationStorage.migrate(toICloud: on)
            syncAudioToICloud = on
            iCloudMigration = .idle
        } catch {
            iCloudMigration = .failed(error.localizedDescription)
        }
    }

    /// Folder holding all clones. Created on first access.
    var reposRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Repos", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

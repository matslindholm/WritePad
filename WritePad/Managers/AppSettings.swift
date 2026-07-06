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

    init() {
        githubToken = Keychain.string(for: Self.tokenAccount) ?? ""
    }

    /// Folder holding all clones. Created on first access.
    var reposRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Repos", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

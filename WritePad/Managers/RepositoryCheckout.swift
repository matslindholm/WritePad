import Foundation
import SwiftGit

/// Clones and refreshes manuscript repositories in-process (no `git` binary),
/// so it works inside the iPadOS sandbox. All git work runs off the main actor.
struct RepositoryCheckout {
    /// Clones `cloneURL` into `destination`. Removes a stale destination first
    /// so a retry after a failed clone starts clean.
    nonisolated func clone(from cloneURL: URL, token: String?, to destination: URL) async throws {
        try await runOffMain {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            _ = try Repository.clone(from: cloneURL, to: destination,
                                     credentials: Self.credentials(token))
        }
    }

    /// Keeps a checkout recent: fetches, then hard-checks-out the latest commit
    /// on the remote default branch. Read-only mirror semantics — the working
    /// tree always matches the remote, never merged.
    nonisolated func refresh(at repoURL: URL, cloneURL: URL, token: String?, branch: String) async throws {
        try await runOffMain {
            let repo = try Repository(opening: repoURL)
            try repo.fetch(from: cloneURL, credentials: Self.credentials(token))
            // New objects arrived on disk; re-open so the ODB sees them.
            let reopened = try Repository(opening: repoURL)
            let tip = try reopened.revParse("refs/remotes/origin/\(branch)")
            try reopened.checkout(commit: tip)
        }
    }

    private static func credentials(_ token: String?) -> HTTPTransport.Credentials? {
        guard let token, !token.isEmpty else { return nil }
        // GitHub accepts a token as the HTTPS username with an empty password.
        return HTTPTransport.Credentials(username: token, password: "")
    }

    private nonisolated func runOffMain<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

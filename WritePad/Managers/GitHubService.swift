import Foundation
import LibGH

/// A repository as surfaced to the UI. A plain value type so the rest of the
/// app never touches `LibGH.Repository` (which would clash with
/// `SwiftGit.Repository`).
struct GitHubRepo: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let defaultBranch: String
    let cloneURL: URL
    let description: String?
    let updatedAt: Date
}

/// Lists the authenticated user's repositories via the GitHub REST API.
struct GitHubService {
    func repositories(token: String) async throws -> [GitHubRepo] {
        let client = GitHubClient(token: token)
        let repos = try await client.repositories(
            options: RepositoryListOptions(sort: .updated, direction: .descending))
        return repos.compactMap(Self.map)
    }

    private static func map(_ repo: Repository) -> GitHubRepo? {
        guard let cloneURL = URL(string: "https://github.com/\(repo.fullName).git") else { return nil }
        return GitHubRepo(
            id: repo.id, name: repo.name, fullName: repo.fullName,
            isPrivate: repo.isPrivate, defaultBranch: repo.defaultBranch,
            cloneURL: cloneURL, description: repo.description, updatedAt: repo.updatedAt)
    }
}

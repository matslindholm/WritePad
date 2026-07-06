import Foundation
import Observation

/// The persisted set of checked-out book projects and their on-disk clones.
/// Backs the sidebar; the JSON index lives in Application Support.
@Observable
final class ProjectLibrary {
    private(set) var projects: [BookProject] = []

    private let settings: AppSettings
    private let checkout = RepositoryCheckout()

    init(settings: AppSettings) {
        self.settings = settings
        load()
    }

    func localURL(for project: BookProject) -> URL {
        settings.reposRootURL.appendingPathComponent(project.folderName, isDirectory: true)
    }

    func contains(fullName: String) -> Bool {
        projects.contains { $0.id == fullName }
    }

    /// Clones a repo and adds it to the library.
    func add(_ repo: GitHubRepo) async throws {
        let folderName = Self.folderName(for: repo.fullName)
        let destination = settings.reposRootURL.appendingPathComponent(folderName, isDirectory: true)
        try await checkout.clone(from: repo.cloneURL,
                                 token: settings.hasToken ? settings.githubToken : nil,
                                 to: destination)
        let project = BookProject(
            id: repo.fullName, name: repo.name, fullName: repo.fullName,
            cloneURL: repo.cloneURL, defaultBranch: repo.defaultBranch,
            folderName: folderName, isPrivate: repo.isPrivate, lastFetched: Date())
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        sortAndSave()
    }

    /// Fetches and re-checks-out the latest commit on the default branch.
    func refresh(_ project: BookProject) async throws {
        try await checkout.refresh(
            at: localURL(for: project), cloneURL: project.cloneURL,
            token: settings.hasToken ? settings.githubToken : nil,
            branch: project.defaultBranch)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastFetched = Date()
            sortAndSave()
        }
    }

    func remove(_ project: BookProject) {
        try? FileManager.default.removeItem(at: localURL(for: project))
        projects.removeAll { $0.id == project.id }
        sortAndSave()
    }

    // MARK: - Persistence

    private var indexURL: URL {
        settings.reposRootURL.appendingPathComponent("library.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([BookProject].self, from: data) else { return }
        projects = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortAndSave() {
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func folderName(for fullName: String) -> String {
        fullName.replacingOccurrences(of: "/", with: "__")
    }
}

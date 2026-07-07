import Foundation
import Observation

/// The persisted set of checked-out book projects and their on-disk clones.
/// Backs the sidebar; the JSON index lives in Application Support.
@Observable
final class ProjectLibrary {
    private(set) var projects: [BookProject] = []

    private let settings: AppSettings
    private let checkout = RepositoryCheckout()
    private var cloudObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        load()
        mergeCloudMarkers()
        cloudObserver = CloudKeyValueStore.observeExternalChanges { [weak self] in
            self?.handleCloudChange()
        }
    }

    func localURL(for project: BookProject) -> URL {
        settings.reposRootURL.appendingPathComponent(project.folderName, isDirectory: true)
    }

    /// Ensures a project is checked out locally, cloning from GitHub on demand.
    /// A project discovered through iCloud sync has an index entry but no clone
    /// on this device until it's opened — this fills that gap. No-op when the
    /// clone already exists.
    func ensureCheckedOut(_ project: BookProject) async throws {
        let url = localURL(for: project)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try await checkout.clone(from: project.cloneURL,
                                 token: settings.hasToken ? settings.githubToken : nil,
                                 to: url)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastFetched = Date()
            sortAndSave()
        }
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
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([BookProject].self, from: data) {
            projects = decoded
        }
        mergeCloudIndex()
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortAndSave() {
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveLocal()
        pushIndexToCloud()
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - iCloud sync

    private func pushIndexToCloud() {
        if let data = try? JSONEncoder().encode(projects) {
            CloudKeyValueStore.set(data, forKey: CloudKeyValueStore.libraryKey)
        }
    }

    /// Folds any books this device hasn't seen into the local index (additive:
    /// a book removed on another device is never auto-removed here, so a local
    /// clone is never deleted behind the user's back). Persists locally when the
    /// set grows; does not push back, so it can't resurrect a book this device
    /// intentionally removed.
    private func mergeCloudIndex() {
        guard let data = CloudKeyValueStore.data(forKey: CloudKeyValueStore.libraryKey),
              let cloud = try? JSONDecoder().decode([BookProject].self, from: data) else { return }
        let known = Set(projects.map(\.id))
        let additions = cloud.filter { !known.contains($0.id) }
        guard !additions.isEmpty else { return }
        projects.append(contentsOf: additions)
        saveLocal()
    }

    /// Merges each book's markers from iCloud into the local marker files.
    private func mergeCloudMarkers() {
        for project in projects {
            NarrationStore(projectKey: project.folderName).mergeMarkersFromCloud()
        }
    }

    private func handleCloudChange() {
        mergeCloudIndex()
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        mergeCloudMarkers()
    }

    private static func folderName(for fullName: String) -> String {
        fullName.replacingOccurrences(of: "/", with: "__")
    }
}

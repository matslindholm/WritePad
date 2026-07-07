import SwiftUI

/// Lists the authenticated user's GitHub repositories and checks one out into
/// the library.
struct AddRepositoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepo] = []
    @State private var loadState: LoadState = .idle
    @State private var cloningID: GitHubRepo.ID?
    @State private var errorMessage: String?

    private enum LoadState { case idle, loading, loaded, failed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add a Book")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .macSheetFrame()
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.hasToken {
            ContentUnavailableView(
                "No GitHub Token", systemImage: "key",
                description: Text("Add a personal access token in Settings to browse your repositories."))
        } else {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading repositories…")
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't Load Repositories", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "Unknown error.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            case .loaded:
                repoList
            }
        }
    }

    private var repoList: some View {
        List(repos) { repo in
            RepoRow(repo: repo,
                    isCloning: cloningID == repo.id,
                    isAdded: library.contains(fullName: repo.fullName)) {
                Task { await clone(repo) }
            }
        }
    }

    private func loadIfNeeded() async {
        guard settings.hasToken, loadState == .idle else { return }
        await load()
    }

    private func load() async {
        loadState = .loading
        do {
            repos = try await GitHubService().repositories(token: settings.githubToken)
            loadState = .loaded
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    private func clone(_ repo: GitHubRepo) async {
        guard cloningID == nil else { return }
        cloningID = repo.id
        errorMessage = nil
        do {
            try await library.add(repo)
        } catch {
            errorMessage = error.localizedDescription
        }
        cloningID = nil
    }
}

private struct RepoRow: View {
    let repo: GitHubRepo
    let isCloning: Bool
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.headline)
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(repo.fullName).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if isCloning {
            ProgressView()
        } else if isAdded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("Add", action: onAdd).buttonStyle(.borderedProminent)
        }
    }
}

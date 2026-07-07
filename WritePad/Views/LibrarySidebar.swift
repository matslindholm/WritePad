import SwiftUI

/// The library sidebar: every checked-out book, plus entry points to add a
/// repository and to open settings.
struct LibrarySidebar: View {
    @Environment(ProjectLibrary.self) private var library

    @Binding var selection: BookProject.ID?
    @Binding var showingAdd: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(library.projects) { project in
                NavigationLink(value: project.id) {
                    ProjectRow(project: project)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("WritePad")
        .overlay {
            if library.projects.isEmpty {
                ContentUnavailableView(
                    "No Books Yet", systemImage: "book.closed",
                    description: Text("Tap + to check out a manuscript from GitHub."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .barLeading) {
                #if os(macOS)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                #else
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                #endif
            }
            ToolbarItem(placement: .barTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add Book", systemImage: "plus")
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            library.remove(library.projects[index])
        }
    }
}

private struct ProjectRow: View {
    let project: BookProject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.displayTitle)
                .font(.headline)
            HStack(spacing: 6) {
                if project.isPrivate {
                    Image(systemName: "lock.fill").font(.caption2)
                }
                Text(project.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

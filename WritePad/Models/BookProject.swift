import Foundation

/// A manuscript repository the user checked out from GitHub. The library
/// persists these; the working copy lives on disk under the repos root.
struct BookProject: Identifiable, Codable, Equatable {
    /// GitHub full name, e.g. "mats/Am_Ende_des_Weges". Stable identity.
    let id: String
    var name: String
    var fullName: String
    var cloneURL: URL
    var defaultBranch: String
    /// Folder name under the repos root that holds the clone.
    var folderName: String
    var isPrivate: Bool
    var lastFetched: Date?

    init(id: String, name: String, fullName: String, cloneURL: URL,
         defaultBranch: String, folderName: String, isPrivate: Bool,
         lastFetched: Date? = nil) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.cloneURL = cloneURL
        self.defaultBranch = defaultBranch
        self.folderName = folderName
        self.isPrivate = isPrivate
        self.lastFetched = lastFetched
    }

    var displayTitle: String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// Canonical, format-independent identity for a repo: its clone URL with the
    /// scheme, any embedded credentials, host case, a trailing slash, and a
    /// `.git` suffix normalized away (e.g. `github.com/owner/repo`). The same
    /// manuscript yields the same key however its URL was entered, so it maps to
    /// one clone and one audio cache instead of one-per-URL-variant.
    static func normalizedKey(for cloneURL: URL) -> String {
        var s = cloneURL.absoluteString.lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }   // strip token/user
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// The normalized key as a filesystem-safe folder name — the storage key for
    /// the clone directory and the narration cache.
    static func storageKey(for cloneURL: URL) -> String {
        normalizedKey(for: cloneURL)
            .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
    }
}

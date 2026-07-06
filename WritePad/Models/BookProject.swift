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
}

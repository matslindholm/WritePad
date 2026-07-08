import Foundation

/// Resolves *where* the narration cache lives — local (Application Support) or
/// the app's iCloud ubiquity container — and moves data between the two when the
/// user flips the "Store audio in iCloud" option. `NarrationStore` is the
/// per-project file API; this owns the root and the iCloud plumbing.
///
/// iCloud is opt-in and degrades gracefully: if the user hasn't enabled it, or
/// iCloud is unavailable (not signed in, entitlement absent), everything falls
/// back to local storage and the app behaves exactly as before.
enum NarrationStorage {
    /// Mirrors `AppSettings.syncAudioToICloud` into UserDefaults so the active
    /// root can be resolved off the main actor without reaching the settings
    /// object (`NarrationStore` is created ad hoc, often on background tasks).
    static let iCloudEnabledKey = "syncAudioToICloud"

    enum StorageError: LocalizedError {
        /// No iCloud account on the device.
        case notSignedIn
        /// Signed in, but the app's iCloud container isn't reachable — usually the
        /// iCloud Documents capability isn't provisioned for this build, or iCloud
        /// Drive is off for WritePad.
        case containerUnavailable
        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                #if os(macOS)
                return "iCloud isn't available to WritePad. Check that you're signed in and iCloud Drive is on: System Settings → your name → iCloud → iCloud Drive."
                #else
                return "iCloud isn't available to WritePad. Check that you're signed in and iCloud Drive is on in Settings."
                #endif
            case .containerUnavailable:
                return "iCloud is signed in, but WritePad's iCloud storage isn't available. Check that iCloud Drive is on for WritePad, and that this build has the iCloud Documents capability. (On Simulator or a locally-signed build, iCloud storage is often unavailable — try a device build.)"
            }
        }
    }

    private static let lock = NSLock()
    private static var cachedICloudRoot: URL?

    /// Local home, in Application Support so expensive-to-rebuild audio isn't
    /// purged the way a cache can be.
    static var localRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Narration", isDirectory: true)
    }

    /// The iCloud ubiquity-container home, or nil when iCloud is unavailable.
    /// The first call is blocking (it provisions the container), so it's cached;
    /// `prime()` warms it off the main thread at launch.
    static func iCloudRoot() -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedICloudRoot { return cached }
        // Only a *successful* lookup is cached — a nil result is retried on the
        // next call, so the container becoming available later (after sign-in or
        // once provisioned) isn't masked for the rest of the session.
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            cachedICloudRoot = container.appendingPathComponent("Narration", isDirectory: true)
        }
        return cachedICloudRoot
    }

    /// Why the container is unavailable, for a precise error rather than a
    /// blanket "sign in to iCloud".
    static var unavailableReason: StorageError {
        FileManager.default.ubiquityIdentityToken == nil ? .notSignedIn : .containerUnavailable
    }

    static var isICloudEnabled: Bool { UserDefaults.standard.bool(forKey: iCloudEnabledKey) }

    /// The root currently in force: iCloud when the user enabled it and iCloud is
    /// reachable, else local.
    static var activeRoot: URL {
        if isICloudEnabled, let cloud = iCloudRoot() { return cloud }
        return localRoot
    }

    /// Warms the (blocking) iCloud container lookup off the main thread. Called at
    /// launch only when the user has iCloud enabled.
    static func prime() {
        Task.detached(priority: .utility) { _ = iCloudRoot() }
    }

    /// Logs whether iCloud is visible to the app, for diagnosing "can't enable"
    /// reports. Runs off the main thread (the container lookup can block).
    static func logDiagnostics() {
        Task.detached(priority: .utility) {
            let signedIn = FileManager.default.ubiquityIdentityToken != nil
            let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.path ?? "nil"
            NSLog("[WritePad iCloud] signedIn=%@ container=%@", signedIn ? "yes" : "no", container)
        }
    }

    // MARK: - iCloud file lifecycle

    /// True when `url` names a file (or an iCloud placeholder for one) — the
    /// iCloud-aware replacement for `fileExists`: an evicted iCloud file's data
    /// isn't on disk, but a hidden `.<name>.icloud` placeholder is.
    static func itemExists(at url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        return fm.fileExists(atPath: placeholder(for: url).path)
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    private static func isDownloaded(_ url: URL) -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        // A non-ubiquitous (plain local) file reports no status — it's "here".
        return status == nil || status == .current
    }

    /// True when `url` is a synced iCloud item whose data isn't on this device
    /// yet — an evicted placeholder awaiting a fetch. False for local files,
    /// already-downloaded files, and items that don't exist at all.
    static func needsDownload(_ url: URL) -> Bool {
        itemExists(at: url) && !isDownloaded(url)
    }

    /// Ensures `url`'s data is on this device, pulling it from iCloud if it's an
    /// evicted placeholder. Bounded wait; a no-op for local files and files
    /// already downloaded.
    static func ensureDownloaded(_ url: URL) async {
        guard itemExists(at: url), !isDownloaded(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<600 {                        // ~60 s ceiling
            if isDownloaded(url) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func ensureDownloaded(_ urls: [URL]) async {
        for url in urls { await ensureDownloaded(url) }
    }

    // MARK: - Migration between local and iCloud

    /// Moves the whole narration tree between local storage and iCloud when the
    /// option is toggled. Runs off the main actor. Enabling requires iCloud to be
    /// reachable; disabling first pulls everything local so nothing is lost.
    static func migrate(toICloud: Bool) async throws {
        guard let cloud = await Task.detached(priority: .utility, operation: { iCloudRoot() }).value else {
            if toICloud { throw unavailableReason }
            return   // already local; nothing to bring down
        }
        let local = localRoot
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if toICloud {
                try moveTree(from: local, to: cloud, makeUbiquitous: true, fm: fm)
            } else {
                try moveTree(from: cloud, to: local, makeUbiquitous: false, fm: fm)
            }
        }.value
    }

    /// Relocates every file under `src` to the matching path under `dst` via
    /// `setUbiquitous`, one file at a time so partial states and collisions are
    /// handled (a file already at the destination is left alone). When bringing
    /// data *out* of iCloud, each file is downloaded first so its bytes come home
    /// rather than being lost with the placeholder.
    private static func moveTree(from src: URL, to dst: URL, makeUbiquitous: Bool, fm: FileManager) throws {
        guard fm.fileExists(atPath: src.path) else { return }
        // Snapshot the file list up front — `setUbiquitous` removes each source
        // file, which would disturb a live directory enumeration.
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let files = walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false
        }
        for item in files {
            let relative = item.path.replacingOccurrences(of: src.path + "/", with: "")
            let target = dst.appendingPathComponent(relative)
            if itemExistsSync(at: target, fm: fm) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !makeUbiquitous { try? fm.startDownloadingUbiquitousItem(at: item) }
            try fm.setUbiquitous(makeUbiquitous, itemAt: item, destinationURL: target)
        }
        try? fm.removeItem(at: src)
    }

    // MARK: - Storage-key normalization

    /// True while any file in the iCloud narration tree is still uploading, so a
    /// key-rename migration can defer until sync settles rather than move files
    /// out from under an in-flight transfer.
    static func hasPendingUploads() -> Bool {
        guard isICloudEnabled, let root = iCloudRoot(),
              FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.ubiquitousItemIsUploadingKey]) else { return false }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey]))?
                .ubiquitousItemIsUploading == true { return true }
        }
        return false
    }

    /// Moves a project's narration cache from one storage key to another under
    /// the active root, merging file-by-file and never overwriting (content-
    /// addressed chunks are identical, so a collision is safe to skip). A plain
    /// move within the same store — within the iCloud container it stays
    /// ubiquitous, so no re-upload.
    static func renameProjectTree(from oldKey: String, to newKey: String) {
        let root = activeRoot
        mergeMove(root.appendingPathComponent(oldKey, isDirectory: true),
                  to: root.appendingPathComponent(newKey, isDirectory: true))
    }

    /// Recursively moves every file under `src` to the matching path under `dst`,
    /// skipping any the destination already has, then removes the emptied source.
    static func mergeMove(_ src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if !fm.fileExists(atPath: dst.path), (try? fm.moveItem(at: src, to: dst)) != nil { return }
        if let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in items {
                let target = dst.appendingPathComponent(item.lastPathComponent)
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                    mergeMove(item, to: target)
                } else if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: item, to: target)
                }
            }
        }
        try? fm.removeItem(at: src)
    }

    private static func itemExistsSync(at url: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: url.path)
            || fm.fileExists(atPath: url.deletingLastPathComponent()
                .appendingPathComponent("." + url.lastPathComponent + ".icloud").path)
    }
}

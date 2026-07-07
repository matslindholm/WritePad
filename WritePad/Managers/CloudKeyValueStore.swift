import Foundation

/// A small facade over iCloud key–value storage for the handful of *small*,
/// high-value things worth following the user across devices — the checked-out
/// library index and listener markers. Large, regenerable data (chapter audio,
/// read-along timelines) is never stored here.
///
/// Degrades to a silent no-op when iCloud is unavailable (the user isn't signed
/// in, or the entitlement isn't provisioned): reads return nil and writes are
/// dropped, so the app behaves exactly as it did before — just without sync.
///
/// `NSUbiquitousKeyValueStore` caps total storage at ~1 MB across ~1024 keys.
/// The index is one key; markers are one key per book, each a compact JSON blob
/// — comfortably within budget for any realistic library.
enum CloudKeyValueStore {
    private static var store: NSUbiquitousKeyValueStore { .default }

    static let libraryKey = "library.projects"
    static func markersKey(projectKey: String) -> String { "markers." + projectKey }

    static func data(forKey key: String) -> Data? { store.data(forKey: key) }

    static func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
        store.synchronize()
    }

    /// Registers `handler` for changes pushed from another device and kicks off
    /// an initial sync. The returned token must be retained to stay subscribed.
    static func observeExternalChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { _ in handler() }
        store.synchronize()
        return token
    }
}

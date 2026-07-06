import Foundation

/// Persists the security-scoped bookmark for the user's chosen workspace
/// folder (spec section 5, wizard step 1). The resolved URL is handed to
/// QEMU's virtio-9p export once the VM engine lands (M2).
enum WorkspaceStore {
    private static let bookmarkKey = "workspaceBookmark"
    private static let nameKey = "workspaceName"

    static var displayName: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Save a bookmark for a folder URL returned by the document picker.
    /// The URL must be within a startAccessingSecurityScopedResource window
    /// when the bookmark is created.
    static func save(url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }

    /// Resolve the stored bookmark. Caller is responsible for
    /// startAccessingSecurityScopedResource / stopAccessing on the result.
    /// TODO(M2): force-download dataless iCloud items before 9p export
    /// (NSFileManager.startDownloadingUbiquitousItem + file coordination).
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            try? save(url: url)
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}

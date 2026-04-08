import Foundation

/// Manages file storage for downloaded media and app data persistence
class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let settings = AppSettings.shared
    private let profilesFileName = "profiles.json"
    private let mediaIndexFileName = "media_index.json"

    private var appSupportDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("InstaArchive")
    }

    private init() {
        ensureDirectoryExists(appSupportDirectory)
    }

    // MARK: - Directory Management

    /// Ensure a directory exists, creating it if necessary
    @discardableResult
    func ensureDirectoryExists(_ url: URL) -> Bool {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return true
            } catch {
                print("Failed to create directory at \(url.path): \(error)")
                return false
            }
        }
        return true
    }

    /// Create the directory structure for a profile
    func createProfileDirectories(for username: String) {
        let profileDir = settings.profileDirectory(for: username)
        ensureDirectoryExists(profileDir)

        for mediaType in MediaType.allCases {
            let typeDir = settings.mediaDirectory(for: username, type: mediaType)
            ensureDirectoryExists(typeDir)
        }
    }

    /// Get the save path for a media item
    func savePath(for media: DiscoveredMedia, username: String, index: Int = 0) -> URL {
        let dir = settings.mediaDirectory(for: username, type: media.mediaType)
        let timestamp = Int(media.timestamp.timeIntervalSince1970)
        let ext = media.isVideo ? "mp4" : "jpg"
        let suffix = media.mediaURLs.count > 1 ? "_\(index + 1)" : ""
        let filename = "\(media.instagramId)_\(timestamp)\(suffix).\(ext)"
        return dir.appendingPathComponent(filename)
    }

    // MARK: - Profile Persistence

    /// Save profiles to disk
    func saveProfiles(_ profiles: [Profile]) {
        let url = appSupportDirectory.appendingPathComponent(profilesFileName)
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: url, options: .atomicWrite)
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    /// Load profiles from disk
    func loadProfiles() -> [Profile] {
        let url = appSupportDirectory.appendingPathComponent(profilesFileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            print("Failed to load profiles: \(error)")
            return []
        }
    }

    // MARK: - Media Index Persistence

    /// Save downloaded media index to disk
    func saveMediaIndex(_ items: [MediaItem]) {
        let url = appSupportDirectory.appendingPathComponent(mediaIndexFileName)
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomicWrite)
        } catch {
            print("Failed to save media index: \(error)")
        }
    }

    /// Load downloaded media index from disk
    func loadMediaIndex() -> [MediaItem] {
        let url = appSupportDirectory.appendingPathComponent(mediaIndexFileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([MediaItem].self, from: data)
        } catch {
            print("Failed to load media index: \(error)")
            return []
        }
    }

    // MARK: - File Operations

    /// Save data to a file path
    func saveFile(data: Data, to url: URL) throws {
        ensureDirectoryExists(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomicWrite)
    }

    /// Check if a media item has already been downloaded
    func isMediaDownloaded(instagramId: String, in items: [MediaItem]) -> Bool {
        items.contains { $0.instagramId == instagramId }
    }

    /// Delete all downloaded files for a profile
    func deleteProfileFiles(for username: String) {
        let profileDir = settings.profileDirectory(for: username)
        do {
            if fileManager.fileExists(atPath: profileDir.path) {
                try fileManager.removeItem(at: profileDir)
                print("[InstaArchive] Deleted files for @\(username) at \(profileDir.path)")
            }
        } catch {
            print("[InstaArchive] Failed to delete files for @\(username): \(error)")
        }
    }

    /// Get total size of downloaded files for a profile
    func downloadedSize(for username: String) -> Int64 {
        let profileDir = settings.profileDirectory(for: username)
        return directorySize(at: profileDir)
    }

    /// Calculate total size of a directory recursively
    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }

    /// Format bytes into human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

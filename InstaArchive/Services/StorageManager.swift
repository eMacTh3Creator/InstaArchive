import Foundation

/// Manages file storage for downloaded media and app data persistence
class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let settings = AppSettings.shared
    private let profilesFileName = "profiles.json"
    private let mediaIndexFileName = "media_index.json"
    private let knownMediaExtensions = ["mp4", "jpg", "jpeg", "png", "webp"]

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
    func savePath(
        for media: DiscoveredMedia,
        username: String,
        index: Int = 0,
        mediaURL: String? = nil,
        fileExtension: String? = nil
    ) -> URL {
        let dir = settings.mediaDirectory(for: username, type: media.mediaType)
        let filename = baseFileName(for: media, index: index)
        let ext = (fileExtension ?? preferredFileExtension(for: mediaURL, fallbackIsVideo: media.isVideo))
            .lowercased()
        return dir.appendingPathComponent("\(filename).\(ext)")
    }

    /// Find an already-downloaded path for a media item regardless of extension.
    func existingSavePath(for media: DiscoveredMedia, username: String, index: Int = 0, mediaURL: String? = nil) -> URL? {
        let preferred = savePath(for: media, username: username, index: index, mediaURL: mediaURL)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }

        let dir = settings.mediaDirectory(for: username, type: media.mediaType)
        let baseName = baseFileName(for: media, index: index)
        for ext in knownMediaExtensions {
            let candidate = dir.appendingPathComponent("\(baseName).\(ext)")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Infer the expected file extension from the media URL before download.
    func preferredFileExtension(for mediaURL: String?, fallbackIsVideo: Bool) -> String {
        if let ext = fileExtensionFromURL(mediaURL) {
            return ext
        }
        return fallbackIsVideo ? "mp4" : "jpg"
    }

    /// Infer the final file extension from the downloaded bytes, then fall back to URL hints.
    func detectedFileExtension(for data: Data, mediaURL: String?, fallbackIsVideo: Bool) -> String {
        if isMP4(data) { return "mp4" }
        if isJPEG(data) { return "jpg" }
        if isPNG(data) { return "png" }
        if isWEBP(data) { return "webp" }
        return preferredFileExtension(for: mediaURL, fallbackIsVideo: fallbackIsVideo)
    }

    private func baseFileName(for media: DiscoveredMedia, index: Int) -> String {
        let timestamp = Int(media.timestamp.timeIntervalSince1970)
        let suffix = media.mediaURLs.count > 1 ? "_\(index + 1)" : ""
        return "\(media.instagramId)_\(timestamp)\(suffix)"
    }

    private func fileExtensionFromURL(_ mediaURL: String?) -> String? {
        guard let mediaURL, let url = URL(string: mediaURL) else { return nil }
        let pathExt = url.pathExtension.lowercased()
        if !pathExt.isEmpty {
            switch pathExt {
            case "jpeg": return "jpg"
            case "jpg", "png", "webp", "mp4", "mov", "m4v":
                return pathExt == "mov" || pathExt == "m4v" ? "mp4" : pathExt
            default:
                break
            }
        }

        let lowered = mediaURL.lowercased()
        if lowered.contains(".mp4") || lowered.contains("video") {
            return "mp4"
        }
        if lowered.contains(".webp") {
            return "webp"
        }
        if lowered.contains(".png") {
            return "png"
        }
        return nil
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }

    private func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private func isWEBP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return String(data: data.prefix(4), encoding: .ascii) == "RIFF"
            && String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP"
    }

    private func isMP4(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return String(data: data.subdata(in: 4..<8), encoding: .ascii) == "ftyp"
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

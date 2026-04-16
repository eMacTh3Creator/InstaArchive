import Foundation

/// Represents a tracked Instagram profile
struct Profile: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var profilePicURL: String?
    var bio: String?
    var isActive: Bool
    var lastChecked: Date?
    var lastNewContent: Date?
    var totalDownloaded: Int
    var dateAdded: Date
    /// Per-profile check interval in hours. nil = follow global setting.
    var customCheckIntervalHours: Int?
    /// How far back to sync posts, in months. nil = sync all history.
    /// Set once when the profile is added. Applies to posts/reels/videos only
    /// (stories and highlights are inherently recent).
    var syncSinceMonths: Int?

    init(
        id: UUID = UUID(),
        username: String,
        displayName: String = "",
        profilePicURL: String? = nil,
        bio: String? = nil,
        isActive: Bool = true,
        lastChecked: Date? = nil,
        lastNewContent: Date? = nil,
        totalDownloaded: Int = 0,
        dateAdded: Date = Date(),
        customCheckIntervalHours: Int? = nil,
        syncSinceMonths: Int? = nil
    ) {
        self.id = id
        self.username = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.isEmpty ? username : displayName
        self.profilePicURL = profilePicURL
        self.bio = bio
        self.isActive = isActive
        self.lastChecked = lastChecked
        self.lastNewContent = lastNewContent
        self.totalDownloaded = totalDownloaded
        self.dateAdded = dateAdded
        self.customCheckIntervalHours = customCheckIntervalHours
        self.syncSinceMonths = syncSinceMonths
    }

    /// Computed cutoff date from `syncSinceMonths`. nil = no cutoff (sync all).
    var syncSinceDate: Date? {
        guard let months = syncSinceMonths, months > 0 else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: Date())
    }

    /// Effective check interval for this profile (uses global if no custom override)
    func effectiveCheckIntervalHours() -> Int {
        customCheckIntervalHours ?? AppSettings.shared.checkIntervalHours
    }

    /// Whether this profile is due for a scheduled check.
    /// Profiles that have never been checked return false — they must be
    /// explicitly synced first (via "Add & Sync" or manual "Check Now").
    /// This prevents the scheduler from auto-syncing 180 newly-added profiles.
    func isDue() -> Bool {
        guard isActive else { return false }
        guard let lastChecked = lastChecked else { return false }
        let intervalSeconds = TimeInterval(effectiveCheckIntervalHours() * 3600)
        return Date().timeIntervalSince(lastChecked) >= intervalSeconds
    }
}

/// The type of media downloaded from Instagram
enum MediaType: String, Codable, CaseIterable {
    case post = "Posts"
    case reel = "Reels"
    case video = "Videos"
    case highlight = "Highlights"
    case story = "Stories"
    case profilePic = "Profile Pictures"
}

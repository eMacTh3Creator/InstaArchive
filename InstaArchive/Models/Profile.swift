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
        dateAdded: Date = Date()
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

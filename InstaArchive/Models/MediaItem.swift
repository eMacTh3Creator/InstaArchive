import Foundation

/// Represents a single downloaded media item
struct MediaItem: Identifiable, Codable, Hashable {
    let id: UUID
    let profileUsername: String
    let mediaType: MediaType
    let instagramId: String
    let mediaURL: String
    let localPath: String?
    let caption: String?
    let timestamp: Date
    let downloadedAt: Date
    let fileSize: Int64?
    let thumbnailPath: String?

    init(
        id: UUID = UUID(),
        profileUsername: String,
        mediaType: MediaType,
        instagramId: String,
        mediaURL: String,
        localPath: String? = nil,
        caption: String? = nil,
        timestamp: Date = Date(),
        downloadedAt: Date = Date(),
        fileSize: Int64? = nil,
        thumbnailPath: String? = nil
    ) {
        self.id = id
        self.profileUsername = profileUsername
        self.mediaType = mediaType
        self.instagramId = instagramId
        self.mediaURL = mediaURL
        self.localPath = localPath
        self.caption = caption
        self.timestamp = timestamp
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
        self.thumbnailPath = thumbnailPath
    }
}

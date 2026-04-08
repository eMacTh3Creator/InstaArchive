import Foundation
import Combine

/// Observable store managing the list of tracked profiles
class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []

    private let storage = StorageManager.shared

    init() {
        profiles = storage.loadProfiles()
    }

    /// Add a new profile to the store
    func addProfile(_ profile: Profile) {
        guard !profiles.contains(where: { $0.username == profile.username }) else { return }
        profiles.append(profile)
        storage.createProfileDirectories(for: profile.username)
        saveAll()
    }

    /// Remove a profile from the store (keeps downloaded files)
    func removeProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        saveAll()
    }

    /// Remove a profile and delete all its downloaded files and index entries
    func removeProfileAndFiles(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        saveAll()
        // Remove index entries
        DownloadManager.shared.removeMediaIndex(for: profile.username)
        // Delete files from disk
        StorageManager.shared.deleteProfileFiles(for: profile.username)
    }

    /// Persist all profiles to disk
    func saveAll() {
        storage.saveProfiles(profiles)
    }

    /// Update a specific profile
    func updateProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveAll()
        }
    }

    // MARK: - Export / Import

    /// Export profiles to a JSON file at the given URL
    func exportProfiles(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        try data.write(to: url, options: .atomicWrite)
    }

    /// Import profiles from a JSON file, skipping duplicates. Returns count of newly added profiles.
    @discardableResult
    func importProfiles(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode([Profile].self, from: data)

        var added = 0
        for var profile in imported {
            let username = profile.username.lowercased()
            guard !profiles.contains(where: { $0.username == username }) else { continue }
            // Give imported profiles fresh UUIDs to avoid collisions
            profile = Profile(
                username: profile.username,
                displayName: profile.displayName,
                profilePicURL: profile.profilePicURL,
                bio: profile.bio,
                isActive: profile.isActive
            )
            profiles.append(profile)
            storage.createProfileDirectories(for: profile.username)
            added += 1
        }

        if added > 0 { saveAll() }
        return added
    }
}

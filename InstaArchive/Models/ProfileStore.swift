import Foundation
import Combine

/// Observable store managing the list of tracked profiles.
/// Uses manual objectWillChange with debouncing to avoid flooding
/// SwiftUI with re-renders when profiles are added rapidly.
class ProfileStore: ObservableObject {
    // NOT @Published — we manage objectWillChange manually with debouncing
    var profiles: [Profile] = []

    private let storage = StorageManager.shared
    private var _debounceTimer: Timer?

    init() {
        profiles = storage.loadProfiles()
    }

    /// Add a new profile to the store
    func addProfile(_ profile: Profile) {
        guard !profiles.contains(where: { $0.username == profile.username }) else { return }
        profiles.append(profile)
        // Create dirs on background — don't block main thread
        let username = profile.username
        DispatchQueue.global(qos: .utility).async {
            StorageManager.shared.createProfileDirectories(for: username)
        }
        debouncedNotify()
        saveAllAsync()
    }

    /// Remove a profile from the store (keeps downloaded files)
    func removeProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        debouncedNotify()
        saveAllAsync()
    }

    /// Remove a profile and delete all its downloaded files and index entries
    func removeProfileAndFiles(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        debouncedNotify()
        saveAllAsync()
        // Remove index entries and files on background
        let username = profile.username
        DispatchQueue.global(qos: .utility).async {
            DownloadManager.shared.removeMediaIndex(for: username)
            StorageManager.shared.deleteProfileFiles(for: username)
        }
    }

    /// Persist all profiles to disk (synchronous — for callers that need it immediately)
    func saveAll() {
        storage.saveProfiles(profiles)
        debouncedNotify()
    }

    /// Persist all profiles to disk on a background queue
    private func saveAllAsync() {
        let snapshot = profiles
        DispatchQueue.global(qos: .utility).async {
            StorageManager.shared.saveProfiles(snapshot)
        }
    }

    /// Update a specific profile
    func updateProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveAll()
        }
    }

    // MARK: - Debounced UI Notification

    /// Coalesce rapid changes into a single objectWillChange after 200ms of quiet.
    /// This prevents N rapid adds from triggering N full sidebar re-renders.
    private func debouncedNotify() {
        _debounceTimer?.invalidate()
        _debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.objectWillChange.send()
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
        let imported = try decodeImportedProfiles(from: data)

        var added = 0
        for var profile in imported {
            let username = profile.username.lowercased()
            guard !profiles.contains(where: { $0.username == username }) else { continue }
            profile = Profile(
                username: profile.username,
                displayName: profile.displayName,
                profilePicURL: profile.profilePicURL,
                bio: profile.bio,
                isActive: profile.isActive
            )
            profiles.append(profile)
            added += 1
        }

        if added > 0 {
            // Create dirs on background
            let usernames = imported.map { $0.username }
            DispatchQueue.global(qos: .utility).async {
                for u in usernames {
                    StorageManager.shared.createProfileDirectories(for: u)
                }
            }
            debouncedNotify()
            saveAllAsync()
        }
        return added
    }

    private func decodeImportedProfiles(from data: Data) throws -> [Profile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let directProfiles = try? decoder.decode([Profile].self, from: data) {
            return directProfiles
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawProfiles = object["profiles"],
           JSONSerialization.isValidJSONObject(rawProfiles) {
            let wrappedData = try JSONSerialization.data(withJSONObject: rawProfiles, options: [])
            if let wrappedProfiles = try? decoder.decode([Profile].self, from: wrappedData) {
                return wrappedProfiles
            }
        }

        throw NSError(
            domain: "InstaArchive.ProfileImport",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "This file is not a valid InstaArchive profile export.",
                NSLocalizedRecoverySuggestionErrorKey: "Use a JSON export created by InstaArchive. If the file came from another source, open it and confirm it contains a JSON list of profiles."
            ]
        )
    }
}

import Foundation
import Combine

/// Thread-safe counter for concurrent download tracking
final class LockedCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        _value += 1
        let v = _value
        lock.unlock()
        return v
    }
}

/// Status of a download operation
enum DownloadStatus: Equatable {
    case idle
    case checking
    case downloading(progress: Double)
    case completed(newItems: Int)
    case skipped
    case error(String)

    /// Whether this is a "final" state that should publish to the UI immediately
    var isFinal: Bool {
        switch self {
        case .completed, .error, .skipped, .idle: return true
        case .checking, .downloading: return false
        }
    }
}

/// Manages the download queue and orchestrates fetching from Instagram
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    // ---------------------------------------------------------------
    // UI-visible state — NOT @Published. We manage objectWillChange
    // manually with throttling so rapid progress updates don't freeze
    // the UI by triggering constant SwiftUI re-renders.
    // ---------------------------------------------------------------
    var profileStatuses: [String: DownloadStatus] = [:]
    var isRunning = false
    var currentActivity: String = ""
    var totalNewItems: Int = 0
    /// Profiles currently being processed (for concurrent tracking)
    var activeUsernames: Set<String> = []

    // Throttle: publish at most every 300ms for transient states,
    // but always publish immediately for final states (completed/error).
    private var _uiDirty = false
    private var _publishTimer: Timer?
    private let _publishInterval: TimeInterval = 0.3

    private let instagram = InstagramService.shared
    private let storage = StorageManager.shared
    private let settings = AppSettings.shared
    private let log = Logger.shared

    private var downloadedMedia: [MediaItem] = []
    private var downloadedIds: Set<String> = []
    private let mediaLock = NSLock()

    /// Cancellation: per-profile tasks and a global stop flag
    private var profileTasks: [String: Task<Void, Never>] = [:]
    private var checkAllTask: Task<Void, Never>?
    private var stopAllRequested = false

    /// How many items to download before auto-saving the index
    private let saveInterval = 25

    private init() {
        downloadedMedia = storage.loadMediaIndex()
        rebuildIdIndex()
    }

    // MARK: - Throttled UI Publishing

    /// Call from MainActor after mutating any UI-visible state.
    /// Final states (completed, error, idle) publish immediately;
    /// transient states (checking, downloading) are batched.
    @MainActor
    private func notifyUI(immediate: Bool = false) {
        if immediate {
            _uiDirty = false
            objectWillChange.send()
            return
        }
        _uiDirty = true
        if _publishTimer == nil {
            _publishTimer = Timer.scheduledTimer(withTimeInterval: _publishInterval, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self._flushUI()
                }
            }
            RunLoop.main.add(_publishTimer!, forMode: .common)
        }
    }

    @MainActor
    private func _flushUI() {
        if _uiDirty {
            _uiDirty = false
            objectWillChange.send()
        } else {
            _publishTimer?.invalidate()
            _publishTimer = nil
        }
    }

    private func rebuildIdIndex() {
        downloadedIds = Set(downloadedMedia.map { $0.instagramId })
    }

    func validateIndex() {
        mediaLock.lock()
        let fm = FileManager.default
        let beforeCount = downloadedMedia.count
        downloadedMedia.removeAll { item in
            guard let path = item.localPath else { return true }
            return !fm.fileExists(atPath: path)
        }
        let removed = beforeCount - downloadedMedia.count
        if removed > 0 {
            print("[InstaArchive] Pruned \(removed) stale entries from media index")
            rebuildIdIndex()
            storage.saveMediaIndex(downloadedMedia)
        }
        mediaLock.unlock()
    }

    func removeMediaIndex(for username: String) {
        mediaLock.lock()
        downloadedMedia.removeAll { $0.profileUsername == username }
        rebuildIdIndex()
        storage.saveMediaIndex(downloadedMedia)
        mediaLock.unlock()
    }

    // MARK: - Cancellation

    /// Skip/cancel download for a specific profile
    func skipProfile(_ username: String) {
        profileTasks[username]?.cancel()
        profileTasks.removeValue(forKey: username)
        Task { @MainActor in
            self.profileStatuses[username] = .skipped
            self.activeUsernames.remove(username)
            if self.activeUsernames.isEmpty {
                self.isRunning = false
                self.currentActivity = ""
            }
            self.notifyUI(immediate: true)
        }
    }

    /// Stop all running downloads
    func stopAll() {
        stopAllRequested = true
        checkAllTask?.cancel()
        for (username, task) in profileTasks {
            task.cancel()
            Task { @MainActor in
                if case .downloading = self.profileStatuses[username] {
                    self.profileStatuses[username] = .skipped
                } else if case .checking = self.profileStatuses[username] {
                    self.profileStatuses[username] = .skipped
                }
            }
        }
        profileTasks.removeAll()
        Task { @MainActor in
            self.activeUsernames.removeAll()
            self.isRunning = false
            self.currentActivity = ""
            self.notifyUI(immediate: true)
        }
    }

    // MARK: - Thread-safe media index helpers

    private func isDownloaded(_ id: String) -> Bool {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedIds.contains(id)
    }

    private func allCarouselItemsDownloaded(baseId: String, count: Int) -> Bool {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return (0..<count).allSatisfy { downloadedIds.contains("\(baseId)_\($0)") }
    }

    private func recordDownload(_ item: MediaItem) {
        mediaLock.lock()
        downloadedMedia.append(item)
        downloadedIds.insert(item.instagramId)
        let count = downloadedMedia.count
        mediaLock.unlock()

        // Periodic save
        if count % saveInterval == 0 {
            saveIndex()
        }
    }

    private func saveIndex() {
        mediaLock.lock()
        let snapshot = downloadedMedia
        mediaLock.unlock()
        storage.saveMediaIndex(snapshot)
    }

    private func currentKnownIds() -> Set<String> {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedIds
    }

    // MARK: - Check single profile

    func checkProfile(_ profile: Profile, profileStore: ProfileStore) {
        guard !activeUsernames.contains(profile.username) else { return }

        let task = Task {
            await performCheck(profile, profileStore: profileStore)
        }
        profileTasks[profile.username] = task
    }

    private func performCheck(_ profile: Profile, profileStore: ProfileStore) async {
        let username = profile.username

        await MainActor.run {
            self.isRunning = true
            self.activeUsernames.insert(username)
            self.profileStatuses[username] = .checking
            self.currentActivity = "Validating index for @\(username)..."
            self.notifyUI(immediate: true)
        }

        log.info("Starting check for @\(username)", context: "check")
        validateIndex()

        do {
            try Task.checkCancellation()

            // 1. Fetch profile info
            log.info("Fetching profile info for @\(username)", context: "check")
            let profileInfo: InstagramProfileInfo
            do {
                profileInfo = try await instagram.fetchProfileInfo(username: username)
                log.info("Got profile info: \(profileInfo.postCount) posts, userId=\(profileInfo.userId)", context: "check")
            } catch {
                log.error("Failed to fetch profile info for @\(username): \(error.localizedDescription)", context: "check")
                throw error
            }

            var allMedia: [DiscoveredMedia] = []
            var warnings: [String] = []

            // 2. Profile picture
            if let profilePicMedia = instagram.makeProfilePicMedia(profileInfo: profileInfo) {
                allMedia.append(profilePicMedia)
            }

            // 3. Posts with full pagination
            try Task.checkCancellation()
            await MainActor.run {
                self.currentActivity = "Fetching posts for @\(username)..."
                self.notifyUI()
            }
            log.info("Fetching posts for @\(username)", context: "check")
            do {
                let posts = try await instagram.fetchAllMedia(
                    username: username,
                    knownIds: currentKnownIds()
                )
                allMedia.append(contentsOf: posts)
                log.info("Found \(posts.count) posts for @\(username)", context: "check")
            } catch {
                log.error("Failed to fetch posts for @\(username): \(error.localizedDescription)", context: "check")
                throw error
            }

            // 4. Stories (non-fatal — log warning on failure)
            try Task.checkCancellation()
            if settings.downloadStories, !profileInfo.userId.isEmpty {
                await MainActor.run {
                    self.currentActivity = "Fetching stories for @\(username)..."
                    self.notifyUI()
                }
                do {
                    let stories = try await instagram.fetchStories(
                        userId: profileInfo.userId,
                        username: username
                    )
                    allMedia.append(contentsOf: stories)
                    log.info("Found \(stories.count) stories for @\(username)", context: "check")
                } catch {
                    let msg = "Stories fetch failed for @\(username): \(error.localizedDescription)"
                    log.warn(msg, context: "check")
                    warnings.append("Stories: \(error.localizedDescription)")
                }
            }

            // 5. Highlights (non-fatal — log warning on failure)
            try Task.checkCancellation()
            if settings.downloadHighlights, !profileInfo.userId.isEmpty {
                await MainActor.run {
                    self.currentActivity = "Fetching highlights for @\(username)..."
                    self.notifyUI()
                }
                do {
                    let highlights = try await instagram.fetchHighlights(
                        userId: profileInfo.userId,
                        username: username
                    )
                    allMedia.append(contentsOf: highlights)
                    log.info("Found \(highlights.count) highlights for @\(username)", context: "check")
                } catch {
                    let msg = "Highlights fetch failed for @\(username): \(error.localizedDescription)"
                    log.warn(msg, context: "check")
                    warnings.append("Highlights: \(error.localizedDescription)")
                }
            }

            // Filter
            let newMedia = allMedia.filter { media in
                if isDownloaded(media.instagramId) { return false }
                if media.mediaURLs.count > 1 {
                    if allCarouselItemsDownloaded(baseId: media.instagramId, count: media.mediaURLs.count) {
                        return false
                    }
                }
                return true
            }

            let filteredMedia = newMedia.filter { media in
                switch media.mediaType {
                case .post: return settings.downloadPosts
                case .reel: return settings.downloadReels
                case .video: return settings.downloadVideos
                case .highlight: return settings.downloadHighlights
                case .story: return settings.downloadStories
                case .profilePic: return true
                }
            }

            // Build a flat list of individual download jobs
            struct DownloadJob {
                let media: DiscoveredMedia
                let index: Int
                let url: String
                let itemId: String
                let savePath: URL
            }

            var jobs: [DownloadJob] = []
            storage.createProfileDirectories(for: username)

            for media in filteredMedia {
                for (index, url) in media.mediaURLs.enumerated() {
                    let itemId = media.mediaURLs.count > 1
                        ? "\(media.instagramId)_\(index)"
                        : media.instagramId

                    // Skip already-indexed items
                    if isDownloaded(itemId) { continue }

                    let savePath = storage.savePath(for: media, username: username, index: index)

                    // If file exists on disk but not in index, re-index it without downloading
                    if FileManager.default.fileExists(atPath: savePath.path) {
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: savePath.path)[.size] as? Int64) ?? 0
                        let mediaItem = MediaItem(
                            profileUsername: username,
                            mediaType: media.mediaType,
                            instagramId: itemId,
                            mediaURL: url,
                            localPath: savePath.path,
                            caption: media.caption,
                            timestamp: media.timestamp,
                            fileSize: fileSize,
                            thumbnailPath: nil
                        )
                        recordDownload(mediaItem)
                        continue
                    }

                    jobs.append(DownloadJob(media: media, index: index, url: url, itemId: itemId, savePath: savePath))
                }
            }

            let totalToDownload = jobs.count
            log.info("@\(username): \(totalToDownload) files to download", context: "download")
            // Thread-safe counters for concurrent downloads
            let downloadedCounter = LockedCounter()
            let newItemCounter = LockedCounter()
            let failedCounter = LockedCounter()

            // Download files concurrently — up to maxConcurrentFiles at a time
            let maxConcurrentFiles = settings.maxConcurrentFileDownloads

            try await withThrowingTaskGroup(of: Void.self) { group in
                var launched = 0

                for job in jobs {
                    try Task.checkCancellation()

                    // Throttle: wait for a slot if we've hit the concurrent limit
                    while launched - downloadedCounter.value >= maxConcurrentFiles {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms check
                    }

                    launched += 1

                    group.addTask { [self] in
                        try Task.checkCancellation()

                        do {
                            let data = try await self.instagram.downloadMediaData(from: job.url)
                            try self.storage.saveFile(data: data, to: job.savePath)

                            let mediaItem = MediaItem(
                                profileUsername: username,
                                mediaType: job.media.mediaType,
                                instagramId: job.itemId,
                                mediaURL: job.url,
                                localPath: job.savePath.path,
                                caption: job.media.caption,
                                timestamp: job.media.timestamp,
                                fileSize: Int64(data.count),
                                thumbnailPath: nil
                            )
                            self.recordDownload(mediaItem)
                            newItemCounter.increment()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failedCounter.increment()
                            self.log.warn("Failed to download \(job.itemId): \(error.localizedDescription)", context: "download")
                        }

                        let completed = downloadedCounter.increment()

                        // Update progress — throttled by notifyUI()
                        if completed % 3 == 0 || completed == totalToDownload {
                            let progress = Double(completed) / Double(totalToDownload)
                            await MainActor.run {
                                self.profileStatuses[username] = .downloading(progress: progress)
                                self.currentActivity = "Downloading @\(username) (\(completed)/\(totalToDownload))..."
                                self.notifyUI()  // throttled, won't flood SwiftUI
                            }
                        }
                    }
                }

                // Wait for all downloads to finish
                try await group.waitForAll()
            }

            let newItemCount = newItemCounter.value
            let failedCount = failedCounter.value

            // Final save
            saveIndex()

            let finalNewItemCount = newItemCount
            if failedCount > 0 {
                warnings.append("\(failedCount) file\(failedCount == 1 ? "" : "s") failed to download")
            }

            log.info("@\(username) complete: \(finalNewItemCount) new, \(failedCount) failed", context: "check")

            await MainActor.run {
                if let idx = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) {
                    profileStore.profiles[idx].lastChecked = Date()
                    profileStore.profiles[idx].totalDownloaded += finalNewItemCount
                    if finalNewItemCount > 0 {
                        profileStore.profiles[idx].lastNewContent = Date()
                    }
                    profileStore.saveAll()
                }
                if warnings.isEmpty {
                    self.profileStatuses[username] = .completed(newItems: finalNewItemCount)
                } else {
                    self.profileStatuses[username] = .completed(newItems: finalNewItemCount)
                }
                self.totalNewItems += finalNewItemCount
                self.notifyUI(immediate: true)
            }

        } catch is CancellationError {
            saveIndex()
            log.info("Download cancelled for @\(username)", context: "check")
            await MainActor.run {
                if self.profileStatuses[username] != .skipped {
                    self.profileStatuses[username] = .skipped
                }
                self.notifyUI(immediate: true)
            }
        } catch let error as InstagramError {
            saveIndex()
            log.error("Check failed for @\(username): \(error.localizedDescription)", context: "check")
            if case .sessionError = error {
                instagram.resetSession()
                await MainActor.run { AppSettings.shared.isLoggedIn = false }
            }
            await MainActor.run {
                self.profileStatuses[username] = .error(error.localizedDescription)
                self.notifyUI(immediate: true)
            }
        } catch {
            saveIndex()
            let msg = "\(error.localizedDescription)"
            log.error("Unexpected error for @\(username): \(msg)", context: "check")
            await MainActor.run {
                self.profileStatuses[username] = .error(msg)
                self.notifyUI(immediate: true)
            }
        }

        profileTasks.removeValue(forKey: username)
        await MainActor.run {
            self.activeUsernames.remove(username)
            if self.activeUsernames.isEmpty {
                self.isRunning = false
                self.currentActivity = ""
            }
            self.notifyUI(immediate: true)
        }
    }

    // MARK: - Check all profiles (concurrent)

    func checkAllProfiles(profileStore: ProfileStore) {
        stopAllRequested = false
        let activeProfiles = profileStore.profiles.filter { $0.isActive }
        guard !activeProfiles.isEmpty else { return }

        checkAllTask = Task {
            // Process up to maxConcurrent profiles at once
            let maxConcurrent = settings.maxConcurrentDownloads

            await withTaskGroup(of: Void.self) { group in
                var index = 0
                var running = 0

                for profile in activeProfiles {
                    if stopAllRequested || Task.isCancelled { break }

                    // Wait for a slot to open up
                    while running >= maxConcurrent {
                        // Wait for one to finish
                        await group.next()
                        running -= 1
                    }

                    if stopAllRequested || Task.isCancelled { break }

                    running += 1
                    index += 1
                    let p = profile
                    group.addTask {
                        await self.performCheck(p, profileStore: profileStore)
                    }
                }

                // Wait for remaining tasks
                await group.waitForAll()
            }

            await MainActor.run {
                self.isRunning = false
                self.currentActivity = ""
                self.notifyUI(immediate: true)
            }
        }
    }

    // MARK: - Query

    func mediaItems(for username: String) -> [MediaItem] {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedMedia.filter { $0.profileUsername == username }
    }

    var totalDownloaded: Int {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedMedia.count
    }

    func clearStatus(for username: String) {
        profileStatuses[username] = .idle
        objectWillChange.send()
    }

    func reloadIndex() {
        mediaLock.lock()
        downloadedMedia = storage.loadMediaIndex()
        rebuildIdIndex()
        mediaLock.unlock()
    }
}

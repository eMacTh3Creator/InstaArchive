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
    var activeUsernames: Set<String> = []

    // Throttle: publish at most every 300ms for transient states,
    // but always publish immediately for final states.
    private var _uiDirty = false
    private var _publishTimer: Timer?
    private let _publishInterval: TimeInterval = 0.5

    private let instagram = InstagramService.shared
    private let storage = StorageManager.shared
    private let settings = AppSettings.shared
    private let log = Logger.shared

    private var downloadedMedia: [MediaItem] = []
    private var downloadedIds: Set<String> = []
    private let mediaLock = NSLock()

    // Background queue for heavy I/O (validateIndex, saveIndex)
    private let ioQueue = DispatchQueue(label: "com.instaarchive.io", qos: .utility)

    private var profileTasks: [String: Task<Void, Never>] = [:]
    private var checkAllTask: Task<Void, Never>?
    private var stopAllRequested = false

    private let saveInterval = 25

    private init() {
        downloadedMedia = storage.loadMediaIndex()
        rebuildIdIndex()
    }

    // MARK: - Throttled UI Publishing

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
                Task { @MainActor in self._flushUI() }
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

    // MARK: - Index Management

    private func rebuildIdIndex() {
        downloadedIds = Set(downloadedMedia.map { $0.instagramId })
    }

    /// Validate the media index by pruning entries whose files no longer exist.
    /// Runs entirely on a background queue — does NOT block the main thread.
    private func validateIndexAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async { [self] in
                mediaLock.lock()
                let fm = FileManager.default
                let beforeCount = downloadedMedia.count
                downloadedMedia.removeAll { item in
                    guard let path = item.localPath else { return true }
                    return !fm.fileExists(atPath: path)
                }
                let removed = beforeCount - downloadedMedia.count
                if removed > 0 {
                    log.info("Pruned \(removed) stale entries from media index", context: "index")
                    rebuildIdIndex()
                    storage.saveMediaIndex(downloadedMedia)
                }
                mediaLock.unlock()
                cont.resume()
            }
        }
    }

    func removeMediaIndex(for username: String) {
        mediaLock.lock()
        downloadedMedia.removeAll { $0.profileUsername == username }
        rebuildIdIndex()
        mediaLock.unlock()
        // Save on background
        let snapshot = downloadedMedia
        ioQueue.async { [self] in storage.saveMediaIndex(snapshot) }
    }

    // MARK: - Cancellation

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

        if count % saveInterval == 0 {
            saveIndexAsync()
        }
    }

    /// Save the media index on a background queue — never blocks the calling thread.
    private func saveIndexAsync() {
        mediaLock.lock()
        let snapshot = downloadedMedia
        mediaLock.unlock()
        ioQueue.async { [self] in storage.saveMediaIndex(snapshot) }
    }

    /// Save synchronously (only for final saves before returning from performCheck).
    private func saveIndexSync() {
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

        // Use .detached to guarantee we don't inherit MainActor context
        let task = Task.detached(priority: .userInitiated) { [self] in
            await performCheck(profile, profileStore: profileStore)
        }
        profileTasks[profile.username] = task
    }

    /// Sync a batch of specific profiles (for multi-select).
    /// Uses sequential processing with delays to avoid bot detection.
    func checkProfiles(_ profiles: [Profile], profileStore: ProfileStore) {
        let shuffled = profiles.shuffled()
        checkAllTask = Task.detached(priority: .userInitiated) { [self] in
            for (index, profile) in shuffled.enumerated() {
                if stopAllRequested || Task.isCancelled { break }
                await self.performCheck(profile, profileStore: profileStore)
                if stopAllRequested || Task.isCancelled { break }
                // Inter-profile delay for batches > 1
                if shuffled.count > 1 && index < shuffled.count - 1 {
                    let cooldown = Double.random(in: 20...60)
                    try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
                }
            }
            await MainActor.run {
                self.isRunning = false
                self.currentActivity = ""
                self.notifyUI(immediate: true)
            }
        }
    }

    private func performCheck(_ profile: Profile, profileStore: ProfileStore) async {
        let username = profile.username

        await MainActor.run {
            self.isRunning = true
            self.activeUsernames.insert(username)
            self.profileStatuses[username] = .checking
            self.currentActivity = "Checking @\(username)..."
            self.notifyUI(immediate: true)
        }

        log.info("Starting check for @\(username)", context: "check")

        // Validate index on background — does NOT block main thread
        await validateIndexAsync()

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

            // 4. Stories (non-fatal)
            try Task.checkCancellation()
            if settings.downloadStories, !profileInfo.userId.isEmpty {
                await MainActor.run {
                    self.currentActivity = "Fetching stories for @\(username)..."
                    self.notifyUI()
                }
                do {
                    let stories = try await instagram.fetchStories(
                        userId: profileInfo.userId, username: username
                    )
                    allMedia.append(contentsOf: stories)
                    log.info("Found \(stories.count) stories for @\(username)", context: "check")
                } catch {
                    log.warn("Stories fetch failed for @\(username): \(error.localizedDescription)", context: "check")
                    warnings.append("Stories: \(error.localizedDescription)")
                }
            }

            // 5. Highlights (non-fatal)
            try Task.checkCancellation()
            if settings.downloadHighlights, !profileInfo.userId.isEmpty {
                await MainActor.run {
                    self.currentActivity = "Fetching highlights for @\(username)..."
                    self.notifyUI()
                }
                do {
                    let highlights = try await instagram.fetchHighlights(
                        userId: profileInfo.userId, username: username
                    )
                    allMedia.append(contentsOf: highlights)
                    log.info("Found \(highlights.count) highlights for @\(username)", context: "check")
                } catch {
                    log.warn("Highlights fetch failed for @\(username): \(error.localizedDescription)", context: "check")
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

            // Build flat job list
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

                    if isDownloaded(itemId) { continue }

                    let savePath = storage.savePath(for: media, username: username, index: index)

                    // Re-index files that exist on disk but not in index
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
            let downloadedCounter = LockedCounter()
            let newItemCounter = LockedCounter()
            let failedCounter = LockedCounter()
            let maxConcurrentFiles = settings.maxConcurrentFileDownloads

            try await withThrowingTaskGroup(of: Void.self) { group in
                var launched = 0

                for job in jobs {
                    try Task.checkCancellation()

                    while launched - downloadedCounter.value >= maxConcurrentFiles {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 50_000_000)
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

                        if completed % 5 == 0 || completed == totalToDownload {
                            let progress = Double(completed) / Double(totalToDownload)
                            await MainActor.run {
                                self.profileStatuses[username] = .downloading(progress: progress)
                                self.currentActivity = "Downloading @\(username) (\(completed)/\(totalToDownload))..."
                                self.notifyUI()
                            }
                        }
                    }
                }

                try await group.waitForAll()
            }

            let newItemCount = newItemCounter.value
            let failedCount = failedCounter.value

            // Final save on background
            saveIndexAsync()

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
                self.profileStatuses[username] = .completed(newItems: finalNewItemCount)
                self.totalNewItems += finalNewItemCount
                self.notifyUI(immediate: true)
            }

        } catch is CancellationError {
            saveIndexAsync()
            log.info("Download cancelled for @\(username)", context: "check")
            await MainActor.run {
                if self.profileStatuses[username] != .skipped {
                    self.profileStatuses[username] = .skipped
                }
                self.notifyUI(immediate: true)
            }
        } catch let error as InstagramError {
            saveIndexAsync()
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
            saveIndexAsync()
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

    // MARK: - Check all profiles (sequential with anti-detection)

    func checkAllProfiles(profileStore: ProfileStore) {
        stopAllRequested = false
        var activeProfiles = profileStore.profiles.filter { $0.isActive }
        guard !activeProfiles.isEmpty else { return }

        // Shuffle to avoid predictable ordering — a key bot signal
        let shuffledProfiles = activeProfiles.shuffled()

        checkAllTask = Task.detached(priority: .userInitiated) { [self] in
            let activeProfiles = shuffledProfiles
            // Mass sync: process ONE profile at a time with delays between them.
            // Concurrent profile checks multiply API requests and are the #1
            // trigger for Instagram's automated bot detection.
            let batchSize = 10  // Profiles per batch before a longer cooldown
            var completedInBatch = 0

            for (index, profile) in activeProfiles.enumerated() {
                if stopAllRequested || Task.isCancelled { break }

                await MainActor.run {
                    self.currentActivity = "Queue: \(index + 1)/\(activeProfiles.count) — @\(profile.username)"
                    self.notifyUI()
                }

                await self.performCheck(profile, profileStore: profileStore)
                completedInBatch += 1

                if stopAllRequested || Task.isCancelled { break }

                // Inter-profile cooldown: random 20-60 seconds
                if index < activeProfiles.count - 1 {
                    let cooldown: Double
                    if completedInBatch >= batchSize {
                        // Batch cooldown: every 10 profiles, take a 3-7 minute break
                        cooldown = Double.random(in: 180...420)
                        completedInBatch = 0
                        self.log.info("Batch cooldown: pausing \(Int(cooldown))s after \(batchSize) profiles", context: "rate")
                        await MainActor.run {
                            self.currentActivity = "Cooldown before next batch (\(Int(cooldown))s)..."
                            self.notifyUI()
                        }
                    } else {
                        cooldown = Double.random(in: 20...60)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
                }
            }

            await MainActor.run {
                self.isRunning = false
                self.currentActivity = ""
                self.notifyUI(immediate: true)
            }
        }
    }

    // MARK: - Query

    /// Returns items for a profile. For large indexes, call from background.
    func mediaItems(for username: String) -> [MediaItem] {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedMedia.filter { $0.profileUsername == username }
    }

    /// Async variant that filters on a background queue — safe to call from UI.
    func mediaItemsAsync(for username: String) async -> [MediaItem] {
        await withCheckedContinuation { cont in
            ioQueue.async { [self] in
                mediaLock.lock()
                let result = downloadedMedia.filter { $0.profileUsername == username }
                mediaLock.unlock()
                cont.resume(returning: result)
            }
        }
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

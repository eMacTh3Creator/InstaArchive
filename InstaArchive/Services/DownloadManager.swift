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

/// Manages the download queue and orchestrates fetching from Instagram.
///
/// IMPORTANT: No view observes this object via @EnvironmentObject or @ObservedObject.
/// All UI state is polled by timers in SidebarView/SidebarBottomBar/ProfileDetailView.
/// Therefore NO code in this class needs to run on MainActor. All state is protected
/// by `stateLock` and can be read/written from any thread.
final class DownloadManager: ObservableObject, @unchecked Sendable {
    static let shared = DownloadManager()

    // ---------------------------------------------------------------
    // UI-visible state — protected by stateLock, polled by view timers.
    // ZERO MainActor involvement. Views poll every 1-2 seconds.
    // ---------------------------------------------------------------
    private let stateLock = NSLock()
    private var _profileStatuses: [String: DownloadStatus] = [:]
    private var _isRunning = false
    private var _currentActivity: String = ""
    private var _totalNewItems: Int = 0
    private var _activeUsernames: Set<String> = []

    // Thread-safe accessors for UI polling
    var profileStatuses: [String: DownloadStatus] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _profileStatuses
    }
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }
    var currentActivity: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentActivity
    }
    var totalNewItems: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _totalNewItems
    }
    var activeUsernames: Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeUsernames
    }

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

    // MARK: - State Helpers (all lock-protected, never MainActor)

    private func setStatus(_ status: DownloadStatus, for username: String) {
        stateLock.lock()
        _profileStatuses[username] = status
        stateLock.unlock()
    }

    private func setActivity(_ text: String) {
        stateLock.lock()
        _currentActivity = text
        stateLock.unlock()
    }

    private func markRunning(username: String) {
        stateLock.lock()
        _isRunning = true
        _activeUsernames.insert(username)
        _profileStatuses[username] = .checking
        _currentActivity = "Checking @\(username)..."
        stateLock.unlock()
    }

    private func markFinished(username: String) {
        stateLock.lock()
        _activeUsernames.remove(username)
        if _activeUsernames.isEmpty {
            _isRunning = false
            _currentActivity = ""
        }
        stateLock.unlock()
    }

    private func markAllStopped() {
        stateLock.lock()
        _activeUsernames.removeAll()
        _isRunning = false
        _currentActivity = ""
        stateLock.unlock()
    }

    private func addTotalNewItems(_ count: Int) {
        stateLock.lock()
        _totalNewItems += count
        stateLock.unlock()
    }

    // MARK: - Index Management

    private func rebuildIdIndex() {
        downloadedIds = Set(downloadedMedia.map { $0.instagramId })
    }

    /// Validate the media index by pruning entries whose files no longer exist.
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
        let snapshot = downloadedMedia
        saveIndexSnapshotAsync(snapshot)
    }

    /// Remove media index entries for a profile, but keep stories, highlights, and profile pictures.
    func removePostsIndex(for username: String) {
        let (snapshot, _) = prunePostsIndex(for: [username])
        saveIndexSnapshotAsync(snapshot)
    }

    private func prunePostsIndex(for usernames: Set<String>) -> ([MediaItem], [String: Int]) {
        mediaLock.lock()
        downloadedMedia.removeAll {
            usernames.contains($0.profileUsername) &&
            $0.mediaType != .story &&
            $0.mediaType != .highlight &&
            $0.mediaType != .profilePic
        }
        rebuildIdIndex()
        let snapshot = downloadedMedia
        let remainingCounts = downloadedMedia.reduce(into: [String: Int]()) { counts, item in
            guard usernames.contains(item.profileUsername) else { return }
            counts[item.profileUsername, default: 0] += 1
        }
        mediaLock.unlock()
        return (snapshot, remainingCounts)
    }

    // MARK: - Cancellation

    func skipProfile(_ username: String) {
        profileTasks[username]?.cancel()
        profileTasks.removeValue(forKey: username)
        setStatus(.skipped, for: username)
        markFinished(username: username)
    }

    func stopAll() {
        stopAllRequested = true
        checkAllTask?.cancel()
        stateLock.lock()
        for username in _activeUsernames {
            _profileStatuses[username] = .skipped
        }
        stateLock.unlock()
        for (_, task) in profileTasks { task.cancel() }
        profileTasks.removeAll()
        markAllStopped()
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

    private func saveIndexAsync() {
        mediaLock.lock()
        let snapshot = downloadedMedia
        mediaLock.unlock()
        saveIndexSnapshotAsync(snapshot)
    }

    private func saveIndexSnapshotAsync(_ snapshot: [MediaItem]) {
        ioQueue.async { [self] in storage.saveMediaIndex(snapshot) }
    }

    private func currentKnownIds() -> Set<String> {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedIds
    }

    // MARK: - Check single profile

    func checkProfile(_ profile: Profile, profileStore: ProfileStore) {
        let active = activeUsernames
        guard !active.contains(profile.username) else { return }

        let task = Task.detached(priority: .userInitiated) { [self] in
            await performCheck(profile, profileStore: profileStore)
        }
        profileTasks[profile.username] = task
    }

    /// Sync a batch of specific profiles (for multi-select).
    func checkProfiles(_ profiles: [Profile], profileStore: ProfileStore) {
        let shuffled = profiles.shuffled()
        checkAllTask = Task.detached(priority: .userInitiated) { [self] in
            for (index, profile) in shuffled.enumerated() {
                if stopAllRequested || Task.isCancelled { break }
                await self.performCheck(profile, profileStore: profileStore)
                if stopAllRequested || Task.isCancelled { break }
                if shuffled.count > 1 && index < shuffled.count - 1 {
                    let cooldown = Double.random(in: 45...120)
                    try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
                }
            }
            self.markAllStopped()
        }
    }

    func refreshProfiles(_ profiles: [Profile], profileStore: ProfileStore) {
        let uniqueProfiles = Array(
            Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }).values
        )
        guard !uniqueProfiles.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [self] in
            let refreshableProfiles = uniqueProfiles.filter { !activeUsernames.contains($0.username) }
            guard !refreshableProfiles.isEmpty else { return }

            let usernames = Set(refreshableProfiles.map(\.username))
            for username in usernames {
                setStatus(.checking, for: username)
            }
            setActivity("Preparing \(refreshableProfiles.count) refresh\(refreshableProfiles.count == 1 ? "" : "es")...")

            let remainingCounts = await withCheckedContinuation { (cont: CheckedContinuation<[String: Int], Never>) in
                ioQueue.async { [self] in
                    let (snapshot, counts) = prunePostsIndex(for: usernames)
                    saveIndexSnapshotAsync(snapshot)

                    let postTypes: [MediaType] = [.post, .reel, .video]
                    for profile in refreshableProfiles {
                        log.info("Refreshing @\(profile.username): deleting posts, keeping stories/highlights/profile pictures", context: "refresh")
                        for type in postTypes {
                            let dir = settings.mediaDirectory(for: profile.username, type: type)
                            try? FileManager.default.removeItem(at: dir)
                        }
                    }
                    cont.resume(returning: counts)
                }
            }

            await MainActor.run {
                for profile in refreshableProfiles {
                    if let idx = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) {
                        profileStore.profiles[idx].totalDownloaded = remainingCounts[profile.username, default: 0]
                        profileStore.profiles[idx].lastChecked = nil
                    }
                }
                profileStore.saveAll()
            }

            for profile in refreshableProfiles {
                clearStatus(for: profile.username)
                checkProfile(profile, profileStore: profileStore)
            }
        }
    }

    /// Refresh a profile: delete posts/reels/videos files + index, keep stories/highlights/profile pictures, then re-sync.
    func refreshProfile(_ profile: Profile, profileStore: ProfileStore) {
        refreshProfiles([profile], profileStore: profileStore)
    }

    private func performCheck(_ profile: Profile, profileStore: ProfileStore) async {
        let username = profile.username

        markRunning(username: username)
        log.info("Starting check for @\(username)", context: "check")

        // Validate index on background
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
            setActivity("Fetching posts for @\(username)...")
            log.info("Fetching posts for @\(username)", context: "check")
            do {
                let posts = try await instagram.fetchAllMedia(
                    username: username,
                    knownIds: currentKnownIds(),
                    since: profile.syncSinceDate
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
                setActivity("Fetching stories for @\(username)...")
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
                setActivity("Fetching highlights for @\(username)...")
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
                let preferredSavePath: URL
            }

            var jobs: [DownloadJob] = []
            storage.createProfileDirectories(for: username)

            for media in filteredMedia {
                for (index, url) in media.mediaURLs.enumerated() {
                    let itemId = media.mediaURLs.count > 1
                        ? "\(media.instagramId)_\(index)"
                        : media.instagramId

                    if isDownloaded(itemId) { continue }

                    if let existingPath = storage.existingSavePath(
                        for: media,
                        username: username,
                        index: index,
                        mediaURL: url
                    ) {
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: existingPath.path)[.size] as? Int64) ?? 0
                        let mediaItem = MediaItem(
                            profileUsername: username,
                            mediaType: media.mediaType,
                            instagramId: itemId,
                            mediaURL: url,
                            localPath: existingPath.path,
                            caption: media.caption,
                            timestamp: media.timestamp,
                            fileSize: fileSize,
                            thumbnailPath: nil
                        )
                        recordDownload(mediaItem)
                        continue
                    }

                    let preferredSavePath = storage.savePath(
                        for: media,
                        username: username,
                        index: index,
                        mediaURL: url
                    )

                    jobs.append(DownloadJob(
                        media: media,
                        index: index,
                        url: url,
                        itemId: itemId,
                        preferredSavePath: preferredSavePath
                    ))
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
                            let finalExtension = self.storage.detectedFileExtension(
                                for: data,
                                mediaURL: job.url,
                                fallbackIsVideo: job.media.isVideo
                            )
                            let finalSavePath = self.storage.savePath(
                                for: job.media,
                                username: username,
                                index: job.index,
                                fileExtension: finalExtension
                            )
                            try self.storage.saveFile(data: data, to: finalSavePath)

                            if data.count < 102400 {
                                self.log.warn("Small file: \(job.itemId) = \(data.count) bytes, URL: \(String(job.url.prefix(100)))", context: "download")
                            }

                            if finalSavePath.pathExtension.lowercased() != job.preferredSavePath.pathExtension.lowercased() {
                                self.log.info(
                                    "Adjusted extension for \(job.itemId) to .\(finalSavePath.pathExtension.lowercased())",
                                    context: "download"
                                )
                            }

                            let mediaItem = MediaItem(
                                profileUsername: username,
                                mediaType: job.media.mediaType,
                                instagramId: job.itemId,
                                mediaURL: job.url,
                                localPath: finalSavePath.path,
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
                            self.setStatus(.downloading(progress: progress), for: username)
                            self.setActivity("Downloading @\(username) (\(completed)/\(totalToDownload))...")
                        }
                    }
                }

                try await group.waitForAll()
            }

            let newItemCount = newItemCounter.value
            let failedCount = failedCounter.value

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
            }
            setStatus(.completed(newItems: finalNewItemCount), for: username)
            addTotalNewItems(finalNewItemCount)

        } catch is CancellationError {
            saveIndexAsync()
            log.info("Download cancelled for @\(username)", context: "check")
            let current = profileStatuses[username]
            if current != .skipped { setStatus(.skipped, for: username) }
        } catch let error as InstagramError {
            saveIndexAsync()
            log.error("Check failed for @\(username): \(error.localizedDescription)", context: "check")
            if case .sessionError = error {
                instagram.resetSession()
                AppSettings.shared.isLoggedIn = false
            }
            setStatus(.error(error.localizedDescription), for: username)
        } catch {
            saveIndexAsync()
            let msg = "\(error.localizedDescription)"
            log.error("Unexpected error for @\(username): \(msg)", context: "check")
            setStatus(.error(msg), for: username)
        }

        profileTasks.removeValue(forKey: username)
        markFinished(username: username)
    }

    // MARK: - Check all profiles (sequential with anti-detection)

    func checkAllProfiles(profileStore: ProfileStore) {
        stopAllRequested = false
        let activeProfiles = profileStore.profiles.filter { $0.isActive }
        guard !activeProfiles.isEmpty else { return }

        let shuffledProfiles = activeProfiles.shuffled()

        checkAllTask = Task.detached(priority: .userInitiated) { [self] in
            let profiles = shuffledProfiles
            let batchSize = 10
            var completedInBatch = 0

            for (index, profile) in profiles.enumerated() {
                if stopAllRequested || Task.isCancelled { break }

                self.setActivity("Queue: \(index + 1)/\(profiles.count) — @\(profile.username)")

                await self.performCheck(profile, profileStore: profileStore)
                completedInBatch += 1

                if stopAllRequested || Task.isCancelled { break }

                if index < profiles.count - 1 {
                    let cooldown: Double
                    if completedInBatch >= batchSize {
                        cooldown = Double.random(in: 300...600)
                        completedInBatch = 0
                        self.log.info("Batch cooldown: pausing \(Int(cooldown))s after \(batchSize) profiles", context: "rate")
                        self.setActivity("Cooldown before next batch (\(Int(cooldown / 60))min)...")
                    } else {
                        cooldown = Double.random(in: 45...120)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
                }
            }

            self.markAllStopped()
        }
    }

    // MARK: - Query

    func mediaItems(for username: String) -> [MediaItem] {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return downloadedMedia.filter { $0.profileUsername == username }
    }

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
        setStatus(.idle, for: username)
    }

    func reloadIndex() {
        mediaLock.lock()
        downloadedMedia = storage.loadMediaIndex()
        rebuildIdIndex()
        mediaLock.unlock()
    }
}

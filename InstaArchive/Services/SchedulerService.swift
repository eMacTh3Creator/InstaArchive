import Foundation
import Combine
import UserNotifications

/// Manages the background scheduling of profile checks.
/// Supports per-profile check intervals with a "Follow Global" default.
class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    @Published var nextCheckDate: Date?
    @Published var isSchedulerActive = false

    /// Fires every 60 seconds to check if any profile is due
    private var timer: Timer?
    private let settings = AppSettings.shared
    private let downloadManager = DownloadManager.shared
    private let log = Logger.shared

    private init() {
        requestNotificationPermission()
    }

    // MARK: - Scheduling

    /// Start the background scheduler.
    /// Uses a 60-second tick to evaluate per-profile schedules.
    func start(profileStore: ProfileStore) {
        stop()
        isSchedulerActive = true

        // Calculate initial next-check for display
        updateNextCheckDate(profileStore: profileStore)

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.tick(profileStore: profileStore)
            }
        }

        // Run on common mode so it fires during scrolling etc.
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        log.info("Scheduler started (60s tick, per-profile intervals)", context: "scheduler")
    }

    /// Stop the background scheduler
    func stop() {
        timer?.invalidate()
        timer = nil
        isSchedulerActive = false
        nextCheckDate = nil
        log.info("Scheduler stopped", context: "scheduler")
    }

    /// Restart with updated settings
    func restart(profileStore: ProfileStore) {
        start(profileStore: profileStore)
    }

    // MARK: - Tick

    /// Called every 60 seconds. Checks which profiles are due and syncs them.
    private func tick(profileStore: ProfileStore) async {
        let dueProfiles = profileStore.profiles.filter { $0.isDue() }

        if !dueProfiles.isEmpty && !downloadManager.isRunning {
            log.info("Scheduler: \(dueProfiles.count) profile(s) due for check", context: "scheduler")
            await performScheduledCheck(profiles: dueProfiles, profileStore: profileStore)
        }

        // Update the next-check display
        await MainActor.run {
            self.updateNextCheckDate(profileStore: profileStore)
        }
    }

    // MARK: - Scheduled Check

    private func performScheduledCheck(profiles: [Profile], profileStore: ProfileStore) async {
        log.info("Running scheduled check for \(profiles.count) profile(s)...", context: "scheduler")

        // Run the batch through DownloadManager's sequential queue so the
        // scheduler does not blast a large number of profiles in parallel.
        downloadManager.checkProfiles(profiles, profileStore: profileStore)

        // The batch starts on a detached task, so give it a brief window to
        // flip into the running state before we begin polling for completion.
        let startDeadline = Date().addingTimeInterval(5)
        while !downloadManager.isRunning && Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Wait for downloads to finish (polling every 2s)
        while downloadManager.isRunning {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Count new items from statuses
        var totalNewItems = 0
        for profile in profiles {
            if case .completed(let count) = downloadManager.profileStatuses[profile.username] {
                totalNewItems += count
            }
        }

        // Send notification if new content was found
        if totalNewItems > 0 && settings.notificationsEnabled {
            sendNotification(newItems: totalNewItems, profileCount: profiles.count)
        }

        log.info("Scheduled check complete. Found \(totalNewItems) new items.", context: "scheduler")
    }

    // MARK: - Next Check Display

    /// Calculate the soonest profile's next check time for display purposes.
    private func updateNextCheckDate(profileStore: ProfileStore) {
        let activeProfiles = profileStore.profiles.filter { $0.isActive }
        guard !activeProfiles.isEmpty else {
            nextCheckDate = nil
            return
        }

        var soonest: Date?
        for profile in activeProfiles {
            let interval = TimeInterval(profile.effectiveCheckIntervalHours() * 3600)
            let nextCheck = (profile.lastChecked ?? profile.dateAdded).addingTimeInterval(interval)
            if soonest == nil || nextCheck < soonest! {
                soonest = nextCheck
            }
        }
        nextCheckDate = soonest
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    private func sendNotification(newItems: Int, profileCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "InstaArchive"
        content.body = "Downloaded \(newItems) new item\(newItems == 1 ? "" : "s") from \(profileCount) profile\(profileCount == 1 ? "" : "s")."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "scheduled-check-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

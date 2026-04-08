import Foundation
import Combine
import UserNotifications

/// Manages the background scheduling of profile checks
class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    @Published var nextCheckDate: Date?
    @Published var isSchedulerActive = false

    private var timer: Timer?
    private let settings = AppSettings.shared
    private let downloadManager = DownloadManager.shared

    private init() {
        requestNotificationPermission()
    }

    // MARK: - Scheduling

    /// Start the background scheduler
    func start(profileStore: ProfileStore) {
        stop()
        isSchedulerActive = true

        let interval = TimeInterval(settings.checkIntervalHours * 3600)
        nextCheckDate = Date().addingTimeInterval(interval)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.performScheduledCheck(profileStore: profileStore)
            }
        }

        // Also run on the run loop so it fires even when app is in background
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[Scheduler] Started with interval: \(settings.checkIntervalHours)h")
    }

    /// Stop the background scheduler
    func stop() {
        timer?.invalidate()
        timer = nil
        isSchedulerActive = false
        nextCheckDate = nil
        print("[Scheduler] Stopped")
    }

    /// Restart with updated settings
    func restart(profileStore: ProfileStore) {
        start(profileStore: profileStore)
    }

    // MARK: - Scheduled Check

    private func performScheduledCheck(profileStore: ProfileStore) async {
        print("[Scheduler] Running scheduled check...")

        let activeProfiles = profileStore.profiles.filter { $0.isActive }

        // Use the concurrent checkAllProfiles which handles everything internally
        downloadManager.checkAllProfiles(profileStore: profileStore)

        // Wait for downloads to finish
        while downloadManager.isRunning {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Count new items from statuses
        var totalNewItems = 0
        for profile in activeProfiles {
            if case .completed(let count) = downloadManager.profileStatuses[profile.username] {
                totalNewItems += count
            }
        }

        // Update next check date
        let interval = TimeInterval(settings.checkIntervalHours * 3600)
        await MainActor.run {
            self.nextCheckDate = Date().addingTimeInterval(interval)
        }

        // Send notification if new content was found
        if totalNewItems > 0 && settings.notificationsEnabled {
            sendNotification(newItems: totalNewItems, profileCount: activeProfiles.count)
        }

        print("[Scheduler] Check complete. Found \(totalNewItems) new items.")
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

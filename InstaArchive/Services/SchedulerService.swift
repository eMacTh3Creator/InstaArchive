import Foundation
import Combine
import UserNotifications

/// Manages the background scheduling of profile checks.
/// Supports per-profile check intervals with a "Follow Global" default.
class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    @Published var nextCheckDate: Date?
    @Published var isSchedulerActive = false

    /// When set to a future date, the scheduler tick skips without firing any
    /// checks. Persisted to UserDefaults so pauses survive app restarts.
    /// Set by the Stop button (24 h default) and cleared either manually via
    /// `resume()` or automatically once the date passes.
    @Published var pausedUntil: Date? {
        didSet {
            if let date = pausedUntil {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.pauseUntil)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.pauseUntil)
            }
        }
    }

    private enum Keys {
        static let pauseUntil = "schedulerPauseUntil"
    }

    /// Fires every 60 seconds to check if any profile is due
    private var timer: Timer?
    private let settings = AppSettings.shared
    private let downloadManager = DownloadManager.shared
    private let log = Logger.shared

    private init() {
        // Restore persisted pause state (ignore if already expired)
        if let ts = UserDefaults.standard.object(forKey: Keys.pauseUntil) as? TimeInterval {
            let date = Date(timeIntervalSince1970: ts)
            if date > Date() {
                pausedUntil = date
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.pauseUntil)
            }
        }
        requestNotificationPermission()
    }

    // MARK: - Pause / Resume

    /// Pause the scheduler for the given duration (default 24 hours).
    /// Any in-flight batch continues — this only prevents future ticks from
    /// firing new ones. Survives app restarts.
    func pause(for duration: TimeInterval = 24 * 3600) {
        let until = Date().addingTimeInterval(duration)
        pausedUntil = until
        log.info("Scheduler paused until \(until.formatted(date: .abbreviated, time: .shortened))", context: "scheduler")
    }

    /// Clear any active pause so the next tick fires normally.
    func resume() {
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        log.info("Scheduler resumed by user", context: "scheduler")
    }

    /// Human-readable pause description for UI. Nil when not paused.
    var pausedDescription: String? {
        guard let until = pausedUntil, until > Date() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Paused — resumes \(formatter.localizedString(for: until, relativeTo: Date()))"
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
        // Auto-clear expired pause.
        if let until = pausedUntil, until <= Date() {
            await MainActor.run { self.pausedUntil = nil }
            log.info("Scheduler pause expired — resuming normal checks", context: "scheduler")
        }

        // Skip tick entirely if paused.
        if let until = pausedUntil, until > Date() {
            await MainActor.run {
                self.updateNextCheckDate(profileStore: profileStore)
            }
            return
        }

        let dueProfiles = profileStore.profiles.filter { $0.isDue() }

        // Use `isBatchInProgress` (not `isRunning`) — `isRunning` flickers off
        // during per-profile cooldowns, which before v1.6.4 let this tick fire
        // concurrent waves that piled up into a thundering-herd block.
        if !dueProfiles.isEmpty && !downloadManager.isBatchInProgress {
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

        // Poll `isBatchInProgress` — unlike `isRunning` this stays true during
        // per-profile cooldown sleeps, so we correctly wait for the whole batch
        // to finish instead of exiting after the first profile and letting the
        // next tick queue a concurrent wave.
        let startDeadline = Date().addingTimeInterval(5)
        while !downloadManager.isBatchInProgress && Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        while downloadManager.isBatchInProgress {
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

import Foundation
import AppKit
import UserNotifications

/// Checks GitHub releases for new versions and downloads the update zip.
class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private let repoOwner = "eMacTh3Creator"
    private let repoName = "InstaArchive"
    private let defaults = UserDefaults.standard
    private let log = Logger.shared

    private enum Keys {
        static let updateCheckInterval = "updateCheckInterval"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let skippedVersion = "skippedVersion"
    }

    /// "manual", "daily", or "weekly".
    /// "manual" disables scheduled checks entirely — the user must tap "Check Now".
    @Published var checkInterval: String {
        didSet {
            defaults.set(checkInterval, forKey: Keys.updateCheckInterval)
            // Switching to/from "manual" needs the timer torn down or restarted.
            if autoUpdateEnabled {
                startScheduledChecks()
            }
        }
    }

    @Published var autoUpdateEnabled: Bool {
        didSet {
            defaults.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled)
            // React to toggles at runtime so the user doesn't need to restart the app.
            if autoUpdateEnabled {
                startScheduledChecks()
            } else {
                stopScheduledChecks()
            }
        }
    }

    @Published var lastCheckDate: Date? {
        didSet { defaults.set(lastCheckDate?.timeIntervalSince1970, forKey: Keys.lastUpdateCheck) }
    }

    @Published var latestVersion: String?
    @Published var updateAvailable: Bool = false
    @Published var isChecking: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0

    private var skippedVersion: String? {
        get { defaults.string(forKey: Keys.skippedVersion) }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    private var checkTimer: Timer?

    private init() {
        self.checkInterval = defaults.string(forKey: Keys.updateCheckInterval) ?? "daily"
        self.autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) as? Bool ?? true
        if let ts = defaults.object(forKey: Keys.lastUpdateCheck) as? TimeInterval {
            self.lastCheckDate = Date(timeIntervalSince1970: ts)
        }
    }

    // MARK: - Current Version

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Lifecycle

    func startScheduledChecks() {
        // Idempotent: tear down any prior timer before scheduling a new one
        // so repeated calls (e.g. toggling auto-update in settings) don't leak.
        stopScheduledChecks()

        guard autoUpdateEnabled, checkInterval != "manual" else { return }

        // Check on launch if due
        if isDueForCheck() {
            Task { await checkForUpdate() }
        }

        // Schedule periodic checks (every 6 hours; actual interval logic is in isDueForCheck)
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self = self, self.autoUpdateEnabled, self.isDueForCheck() else { return }
            Task { await self.checkForUpdate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    func stopScheduledChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func isDueForCheck() -> Bool {
        guard let last = lastCheckDate else { return true }
        let elapsed = Date().timeIntervalSince(last)
        switch checkInterval {
        case "manual":
            return false
        case "weekly":
            return elapsed > 7 * 24 * 3600
        default: // daily
            return elapsed > 24 * 3600
        }
    }

    /// Human-readable "last checked N ago" or "never" for settings UI.
    var lastCheckDescription: String {
        guard let date = lastCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Check for Update

    @MainActor
    func checkForUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        log.info("Checking for updates...", context: "update")

        do {
            let release = try await fetchLatestRelease()
            let remote = release.tagName.replacingOccurrences(of: "v", with: "")
            latestVersion = remote
            lastCheckDate = Date()

            if isNewerVersion(remote, than: currentVersion) {
                if skippedVersion == remote {
                    log.info("Update \(remote) available but skipped by user", context: "update")
                    updateAvailable = false
                } else {
                    log.info("Update available: \(currentVersion) -> \(remote)", context: "update")
                    updateAvailable = true
                    sendUpdateNotification(version: remote)
                }
            } else {
                log.info("Up to date (current: \(currentVersion), latest: \(remote))", context: "update")
                updateAvailable = false
            }
        } catch {
            log.warn("Update check failed: \(error.localizedDescription)", context: "update")
        }
    }

    // MARK: - Download Update

    @MainActor
    func downloadUpdate() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0
        defer { isDownloading = false }

        do {
            let release = try await fetchLatestRelease()
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                log.warn("No .zip asset found in release", context: "update")
                return
            }

            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destURL = downloadsDir.appendingPathComponent(asset.name)

            // Remove existing file if present
            try? FileManager.default.removeItem(at: destURL)

            log.info("Downloading update: \(asset.name) (\(asset.size / 1024)KB)", context: "update")

            guard let url = URL(string: asset.downloadURL) else { return }

            let (tempURL, response) = try await URLSession.shared.download(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                log.warn("Download failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0)", context: "update")
                return
            }

            try FileManager.default.moveItem(at: tempURL, to: destURL)
            downloadProgress = 1.0

            log.info("Update downloaded to: \(destURL.path)", context: "update")
            sendDownloadCompleteNotification(path: destURL.path, version: release.tagName)

            // Open Downloads folder
            NSWorkspace.shared.open(downloadsDir)
        } catch {
            log.warn("Download failed: \(error.localizedDescription)", context: "update")
        }
    }

    func skipVersion(_ version: String) {
        skippedVersion = version
        updateAvailable = false
    }

    // MARK: - GitHub API

    private struct GitHubRelease {
        let tagName: String
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset {
        let name: String
        let downloadURL: String
        let size: Int
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InstaArchive/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        var assets: [GitHubAsset] = []
        if let assetsArray = json["assets"] as? [[String: Any]] {
            for assetJSON in assetsArray {
                if let name = assetJSON["name"] as? String,
                   let downloadURL = assetJSON["browser_download_url"] as? String,
                   let size = assetJSON["size"] as? Int {
                    assets.append(GitHubAsset(name: name, downloadURL: downloadURL, size: size))
                }
            }
        }

        return GitHubRelease(tagName: tagName, assets: assets)
    }

    // MARK: - Version Comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Notifications

    /// Request notification authorization before posting. Silently no-op
    /// if the user denies — the Settings "Updates" section still shows
    /// the update in-app, so permission is not load-bearing.
    private func sendUpdateNotification(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "InstaArchive Update Available"
            content.body = "Version \(version) is available. Open InstaArchive to update."
            content.sound = .default

            let request = UNNotificationRequest(identifier: "update-available", content: content, trigger: nil)
            center.add(request)
        }
    }

    private func sendDownloadCompleteNotification(path: String, version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Update Downloaded"
        content.body = "InstaArchive \(version) has been downloaded to your Downloads folder."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "update-downloaded", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

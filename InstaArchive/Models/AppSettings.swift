import Foundation
import SwiftUI

/// Centralized app settings stored in UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let downloadPath = "downloadPath"
        static let checkIntervalHours = "checkIntervalHours"
        static let launchAtLogin = "launchAtLogin"
        static let showInMenuBar = "showInMenuBar"
        static let downloadPosts = "downloadPosts"
        static let downloadReels = "downloadReels"
        static let downloadVideos = "downloadVideos"
        static let downloadHighlights = "downloadHighlights"
        static let downloadStories = "downloadStories"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let maxConcurrentFileDownloads = "maxConcurrentFileDownloads"
        static let notificationsEnabled = "notificationsEnabled"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let isLoggedIn = "isLoggedIn"
        static let webServerEnabled = "webServerEnabled"
        static let webServerPassword = "webServerPassword"
        static let ignoreSystemProxyForInstagram = "ignoreSystemProxyForInstagram"
    }

    @Published var downloadPath: String {
        didSet { defaults.set(downloadPath, forKey: Keys.downloadPath) }
    }

    @Published var checkIntervalHours: Int {
        didSet { defaults.set(checkIntervalHours, forKey: Keys.checkIntervalHours) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }

    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Keys.showInMenuBar) }
    }

    @Published var downloadPosts: Bool {
        didSet { defaults.set(downloadPosts, forKey: Keys.downloadPosts) }
    }

    @Published var downloadReels: Bool {
        didSet { defaults.set(downloadReels, forKey: Keys.downloadReels) }
    }

    @Published var downloadVideos: Bool {
        didSet { defaults.set(downloadVideos, forKey: Keys.downloadVideos) }
    }

    @Published var downloadHighlights: Bool {
        didSet { defaults.set(downloadHighlights, forKey: Keys.downloadHighlights) }
    }

    @Published var downloadStories: Bool {
        didSet { defaults.set(downloadStories, forKey: Keys.downloadStories) }
    }

    @Published var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads) }
    }

    /// Number of media files to download simultaneously per profile
    @Published var maxConcurrentFileDownloads: Int {
        didSet { defaults.set(maxConcurrentFileDownloads, forKey: Keys.maxConcurrentFileDownloads) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var isLoggedIn: Bool {
        didSet { defaults.set(isLoggedIn, forKey: Keys.isLoggedIn) }
    }

    @Published var webServerEnabled: Bool {
        didSet { defaults.set(webServerEnabled, forKey: Keys.webServerEnabled) }
    }

    @Published var webServerPassword: String {
        didSet { defaults.set(webServerPassword, forKey: Keys.webServerPassword) }
    }

    @Published var ignoreSystemProxyForInstagram: Bool {
        didSet { defaults.set(ignoreSystemProxyForInstagram, forKey: Keys.ignoreSystemProxyForInstagram) }
    }

    private init() {
        let defaultDownloadPath = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("InstaArchive").path ?? "~/Pictures/InstaArchive"

        self.downloadPath = defaults.string(forKey: Keys.downloadPath) ?? defaultDownloadPath
        self.checkIntervalHours = defaults.object(forKey: Keys.checkIntervalHours) as? Int ?? 24
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.showInMenuBar = defaults.object(forKey: Keys.showInMenuBar) as? Bool ?? true
        self.downloadPosts = defaults.object(forKey: Keys.downloadPosts) as? Bool ?? true
        self.downloadReels = defaults.object(forKey: Keys.downloadReels) as? Bool ?? true
        self.downloadVideos = defaults.object(forKey: Keys.downloadVideos) as? Bool ?? true
        self.downloadHighlights = defaults.object(forKey: Keys.downloadHighlights) as? Bool ?? true
        self.downloadStories = defaults.object(forKey: Keys.downloadStories) as? Bool ?? false
        self.maxConcurrentDownloads = defaults.object(forKey: Keys.maxConcurrentDownloads) as? Int ?? 3
        self.maxConcurrentFileDownloads = defaults.object(forKey: Keys.maxConcurrentFileDownloads) as? Int ?? 6
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.isLoggedIn = defaults.bool(forKey: Keys.isLoggedIn)
        self.webServerEnabled = defaults.object(forKey: Keys.webServerEnabled) as? Bool ?? true
        self.webServerPassword = defaults.string(forKey: Keys.webServerPassword) ?? ""
        self.ignoreSystemProxyForInstagram = defaults.object(forKey: Keys.ignoreSystemProxyForInstagram) as? Bool ?? false
    }

    /// Returns the full path for a given profile's download directory
    func profileDirectory(for username: String) -> URL {
        URL(fileURLWithPath: downloadPath).appendingPathComponent(username)
    }

    /// Returns the path for a specific media type within a profile directory
    func mediaDirectory(for username: String, type: MediaType) -> URL {
        profileDirectory(for: username).appendingPathComponent(type.rawValue)
    }
}

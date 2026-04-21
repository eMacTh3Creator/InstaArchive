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
        // Advanced (Diagnostics) toggles — each re-activates a defensive layer
        // that was added in v1.5–v1.6 in response to Instagram's anti-bot
        // system. All default to `false` so v1.7+ behaves like the simpler
        // v1.3-era downloader; flip these on one at a time if you need the
        // corresponding protection back.
        static let enableCDNUpgrade = "enableCDNUpgrade"
        static let enableJPEGValidation = "enableJPEGValidation"
        static let enablePublicMetadataFallback = "enablePublicMetadataFallback"
        static let useStrictRateLimit = "useStrictRateLimit"
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

    // MARK: - Advanced (Diagnostics)

    /// When ON, the downloader rewrites signed CDN URLs (stripping `stp=..._p480x480`
    /// size directives) to try to get full-resolution images. This breaks the
    /// CDN signature on many paths and is the root cause of v1.5.10-v1.6.11
    /// retry storms. Default OFF — save whatever URL Instagram gave us.
    @Published var enableCDNUpgrade: Bool {
        didSet { defaults.set(enableCDNUpgrade, forKey: Keys.enableCDNUpgrade) }
    }

    /// When ON, the downloader validates image responses against the JPEG
    /// magic bytes (`FF D8 FF`) and rejects anything else. v1.5.13 added
    /// this to catch WebP/AVIF responses being saved with `.jpg` extension,
    /// but it causes hard download failures on modern Instagram CDN nodes
    /// that serve WebP by default. Default OFF — save the bytes, log a warning.
    @Published var enableJPEGValidation: Bool {
        didSet { defaults.set(enableJPEGValidation, forKey: Keys.enableJPEGValidation) }
    }

    /// When ON, use the cached public profile metadata (first 12 posts) as a
    /// fallback when the authenticated and public feed APIs both fail.
    /// v1.6.6+ added this for blocked sessions — but it silently truncates
    /// archives to 12 items when triggered mid-pagination. Default OFF so
    /// failures are visible instead of hidden.
    @Published var enablePublicMetadataFallback: Bool {
        didSet { defaults.set(enablePublicMetadataFallback, forKey: Keys.enablePublicMetadataFallback) }
    }

    /// When ON, use the v1.4 anti-bot rate limits: 5 s base interval + up to
    /// 45 s jitter + depth multiplier + hard 100 req/hour cap. When OFF
    /// (default), a lighter limiter is used: 3 s base + 0–5 s jitter, 500
    /// req/hour cap, no depth multiplier. Flip on only if Instagram starts
    /// rate-limiting you in the relaxed mode.
    @Published var useStrictRateLimit: Bool {
        didSet { defaults.set(useStrictRateLimit, forKey: Keys.useStrictRateLimit) }
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
        self.enableCDNUpgrade = defaults.object(forKey: Keys.enableCDNUpgrade) as? Bool ?? false
        self.enableJPEGValidation = defaults.object(forKey: Keys.enableJPEGValidation) as? Bool ?? false
        self.enablePublicMetadataFallback = defaults.object(forKey: Keys.enablePublicMetadataFallback) as? Bool ?? false
        self.useStrictRateLimit = defaults.object(forKey: Keys.useStrictRateLimit) as? Bool ?? false
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

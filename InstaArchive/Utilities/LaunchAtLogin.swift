import Foundation
import ServiceManagement

/// Manages launch-at-login functionality using SMAppService (macOS 13+)
/// Falls back to SMLoginItemSetEnabled for older macOS versions.
enum LaunchAtLogin {

    /// Enable or disable launch at login
    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "register" : "unregister") launch at login: \(error)")
            }
        } else {
            // Fallback for macOS 12 and earlier
            let bundleId = Bundle.main.bundleIdentifier ?? "com.instaarchive.app"
            SMLoginItemSetEnabled(bundleId as CFString, enabled)
        }
    }

    /// Check if launch at login is currently enabled
    @available(macOS 13.0, *)
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

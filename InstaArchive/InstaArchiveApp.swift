import SwiftUI
import UniformTypeIdentifiers

// MARK: - Focused Value Keys

extension FocusedValues {
    struct SelectedProfileKey: FocusedValueKey {
        typealias Value = Binding<Profile?>
    }
    struct ShowingAddProfileKey: FocusedValueKey {
        typealias Value = Binding<Bool>
    }
    struct ShowingSettingsKey: FocusedValueKey {
        typealias Value = Binding<Bool>
    }
    struct CheckAllActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    var selectedProfile: Binding<Profile?>? {
        get { self[SelectedProfileKey.self] }
        set { self[SelectedProfileKey.self] = newValue }
    }
    var showingAddProfile: Binding<Bool>? {
        get { self[ShowingAddProfileKey.self] }
        set { self[ShowingAddProfileKey.self] = newValue }
    }
    var showingSettings: Binding<Bool>? {
        get { self[ShowingSettingsKey.self] }
        set { self[ShowingSettingsKey.self] = newValue }
    }
    var checkAllAction: (() -> Void)? {
        get { self[CheckAllActionKey.self] }
        set { self[CheckAllActionKey.self] = newValue }
    }
}

@main
struct InstaArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var scheduler = SchedulerService.shared
    @StateObject private var webServer = WebServer.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showMainWindow = true

    @FocusedBinding(\.selectedProfile) var selectedProfile
    @FocusedBinding(\.showingAddProfile) var showingAddProfile
    @FocusedBinding(\.showingSettings) var showingSettings
    @FocusedValue(\.checkAllAction) var checkAllAction

    var body: some Scene {
        // Main window
        WindowGroup {
            Group {
                if !settings.hasCompletedOnboarding {
                    OnboardingView {
                        showMainWindow = true
                        scheduler.start(profileStore: profileStore)
                    }
                } else {
                    ContentView()
                }
            }
            .environmentObject(profileStore)
            .environmentObject(downloadManager)
            .environmentObject(scheduler)
            .environmentObject(webServer)
            .onAppear {
                if settings.hasCompletedOnboarding {
                    scheduler.start(profileStore: profileStore)
                }
                if settings.webServerEnabled {
                    webServer.start(profileStore: profileStore)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
        .commands {
            // File menu
            CommandGroup(after: .newItem) {
                Button("Add Profile...") {
                    showingAddProfile = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button("Check All Profiles") {
                    checkAllAction?()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Export Profiles...") {
                    exportProfiles()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import Profiles...") {
                    importProfiles()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            // View menu
            CommandGroup(after: .sidebar) {
                Button("Go Home") {
                    selectedProfile = nil
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Settings...") {
                    showingSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        // Menu bar extra
        MenuBarExtra("InstaArchive", systemImage: "square.and.arrow.down.on.square") {
            MenuBarView(showMainWindow: $showMainWindow)
                .environmentObject(profileStore)
                .environmentObject(downloadManager)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Export / Import Helpers

extension InstaArchiveApp {
    func exportProfiles() {
        let panel = NSSavePanel()
        panel.title = "Export Profiles"
        panel.nameFieldStringValue = "instaarchive-profiles.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try profileStore.exportProfiles(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Import Profiles"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let added = try profileStore.importProfiles(from: url)
            let alert = NSAlert()
            alert.messageText = "Import Complete"
            alert.informativeText = added > 0
                ? "Added \(added) new profile\(added == 1 ? "" : "s")."
                : "No new profiles to import (all already exist)."
            alert.alertStyle = .informational
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

/// App delegate to handle window lifecycle and dock icon visibility
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the download directory exists
        let settings = AppSettings.shared
        StorageManager.shared.ensureDirectoryExists(
            URL(fileURLWithPath: settings.downloadPath)
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen main window when dock icon is clicked
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the background (menubar)
        return false
    }
}

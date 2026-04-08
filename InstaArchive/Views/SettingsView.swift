import SwiftUI
import WebKit

/// Settings window for configuring the app
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var profileStore: ProfileStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var webServer = WebServer.shared
    @State private var showingFolderPicker = false
    @State private var showingLogin = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Instagram Account
                    settingsSection("Instagram Account") {
                        VStack(alignment: .leading, spacing: 8) {
                            if settings.isLoggedIn {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Logged in")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Button("Log Out") {
                                        logOut()
                                    }
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.green.opacity(0.08))
                                .cornerRadius(8)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Not logged in")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Button("Log In") {
                                        showingLogin = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(8)

                                Text("Login is required to download posts, reels, stories, and highlights. Your credentials go directly to Instagram.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Download Location
                    settingsSection("Download Location") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                Text(settings.downloadPath)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Change...") {
                                    chooseFolder()
                                }
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)

                            Text("Each profile will get its own subfolder with media organized by type.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Schedule
                    settingsSection("Schedule") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Check for new content every")
                                Picker("", selection: $settings.checkIntervalHours) {
                                    Text("1 hour").tag(1)
                                    Text("6 hours").tag(6)
                                    Text("12 hours").tag(12)
                                    Text("24 hours").tag(24)
                                    Text("48 hours").tag(48)
                                    Text("7 days").tag(168)
                                }
                                .frame(width: 120)
                            }
                        }
                    }

                    // Content Types
                    settingsSection("Content to Download") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Posts (photos & carousels)", isOn: $settings.downloadPosts)
                            Toggle("Reels", isOn: $settings.downloadReels)
                            Toggle("Videos (IGTV)", isOn: $settings.downloadVideos)
                            Toggle("Highlights", isOn: $settings.downloadHighlights)
                            Toggle("Stories (requires check within 24h)", isOn: $settings.downloadStories)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    // Performance
                    settingsSection("Performance") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Concurrent profiles")
                                    .frame(width: 160, alignment: .leading)
                                Picker("", selection: $settings.maxConcurrentDownloads) {
                                    Text("1").tag(1)
                                    Text("2").tag(2)
                                    Text("3").tag(3)
                                    Text("5").tag(5)
                                }
                                .frame(width: 80)
                            }
                            Text("Number of profiles to download simultaneously.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            HStack {
                                Text("Files per profile")
                                    .frame(width: 160, alignment: .leading)
                                Picker("", selection: $settings.maxConcurrentFileDownloads) {
                                    Text("2").tag(2)
                                    Text("4").tag(4)
                                    Text("6").tag(6)
                                    Text("8").tag(8)
                                    Text("12").tag(12)
                                }
                                .frame(width: 80)
                            }
                            Text("Number of files to download at the same time per profile. Higher values are faster but use more bandwidth.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Behavior
                    settingsSection("Behavior") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                            Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                            Toggle("Show notifications for new downloads", isOn: $settings.notificationsEnabled)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    // Web Interface
                    settingsSection("Web Interface") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable web interface", isOn: $settings.webServerEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: settings.webServerEnabled) { enabled in
                                    if enabled {
                                        webServer.start(profileStore: profileStore)
                                    } else {
                                        webServer.stop()
                                    }
                                }

                            if settings.webServerEnabled && webServer.isRunning {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(webServer.url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Open") {
                                        if let url = URL(string: webServer.url) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.green.opacity(0.08))
                                .cornerRadius(8)
                            }

                            HStack {
                                Text("Password")
                                    .frame(width: 70, alignment: .leading)
                                SecureField("Leave blank for no password", text: $settings.webServerPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }

                            Text("Add and manage profiles from any browser on your local network. Set a password to require login.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Open Download Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                }
                .controlSize(.small)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 780)
        .sheet(isPresented: $showingLogin) {
            InstagramLoginView()
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Location"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadPath = url.path
        }
    }

    private func logOut() {
        // Clear Instagram cookies
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("instagram.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        // Also clear WKWebView cookies
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            for record in records where record.displayName.contains("instagram") {
                dataStore.removeData(ofTypes: record.dataTypes, for: [record]) {}
            }
        }
        InstagramService.shared.resetSession()
        settings.isLoggedIn = false
    }
}

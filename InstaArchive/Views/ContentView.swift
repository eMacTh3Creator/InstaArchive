import SwiftUI

/// Main content view with sidebar navigation and detail panel
struct ContentView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var selectedProfile: Profile?
    @State private var showingAddProfile = false
    @State private var showingSettings = false
    @State private var searchText = ""

    var filteredProfiles: [Profile] {
        if searchText.isEmpty {
            return profileStore.profiles
        }
        return profileStore.profiles.filter {
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                profiles: filteredProfiles,
                selectedProfile: $selectedProfile,
                searchText: $searchText,
                onAdd: { showingAddProfile = true },
                onCheckAll: checkAll,
                onGoHome: { selectedProfile = nil }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let profile = selectedProfile {
                ProfileDetailView(
                    profile: binding(for: profile),
                    onDelete: { selectedProfile = nil }
                )
            } else {
                HomeView()
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .sheet(isPresented: $showingAddProfile) {
            AddProfileView { profile in
                profileStore.addProfile(profile)
                selectedProfile = profile
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { selectedProfile = nil }) {
                    Image(systemName: "house")
                }
                .help("Home (⇧⌘H)")

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .focusedSceneValue(\.selectedProfile, $selectedProfile)
        .focusedSceneValue(\.showingAddProfile, $showingAddProfile)
        .focusedSceneValue(\.showingSettings, $showingSettings)
        .focusedSceneValue(\.checkAllAction, checkAll)
    }

    private func checkAll() {
        downloadManager.checkAllProfiles(profileStore: profileStore)
    }

    private func binding(for profile: Profile) -> Binding<Profile> {
        guard let index = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return .constant(profile)
        }
        return $profileStore.profiles[index]
    }
}

/// Home view with app stats
struct HomeView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var webServer: WebServer
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingLogin = false
    @State private var totalStorage: Int64 = 0

    private var activeCount: Int {
        profileStore.profiles.filter { $0.isActive }.count
    }

    private func calculateStorage() {
        let usernames = profileStore.profiles.map { $0.username }
        Task.detached(priority: .utility) {
            let total = usernames.reduce(Int64(0)) { total, username in
                total + StorageManager.shared.downloadedSize(for: username)
            }
            await MainActor.run { totalStorage = total }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56, weight: .thin))
                .foregroundColor(.secondary)

            Text("InstaArchive")
                .font(.title)
                .fontWeight(.medium)

            // Login prompt
            if !settings.isLoggedIn {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Log in to Instagram to download full profiles")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Button("Log In to Instagram") {
                        showingLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(16)
                .background(Color.orange.opacity(0.06))
                .cornerRadius(10)
            }

            if profileStore.profiles.isEmpty {
                Text("Add a profile to start archiving.")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                // Stats grid
                HStack(spacing: 32) {
                    StatBox(
                        icon: "person.2",
                        value: "\(profileStore.profiles.count)",
                        label: profileStore.profiles.count == 1 ? "Profile" : "Profiles"
                    )

                    StatBox(
                        icon: "play.circle",
                        value: "\(activeCount)",
                        label: "Active"
                    )

                    StatBox(
                        icon: "photo.on.rectangle",
                        value: formattedCount(downloadManager.totalDownloaded),
                        label: "Media Indexed"
                    )

                    StatBox(
                        icon: "externaldrive",
                        value: StorageManager.formatBytes(totalStorage),
                        label: "Storage Used"
                    )
                }
                .padding(.top, 4)

                Text("Select a profile from the sidebar to view its archive.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                if webServer.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Web interface:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button(webServer.url) {
                            if let url = URL(string: webServer.url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentColor)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { calculateStorage() }
        .onChange(of: downloadManager.isRunning) { running in
            if !running { calculateStorage() }
        }
        .sheet(isPresented: $showingLogin) {
            InstagramLoginView()
        }
    }

    private func formattedCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

/// A single stat box for the home screen
struct StatBox: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundColor(.accentColor)

            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 90)
    }
}

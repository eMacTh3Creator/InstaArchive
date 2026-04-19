import SwiftUI

/// Main content view with sidebar navigation and detail panel
struct ContentView: View {
    @EnvironmentObject var profileStore: ProfileStore
    // NOTE: Do NOT observe DownloadManager here — use .shared for actions.
    @State private var selectedProfile: Profile?
    @State private var selectedProfileIds: Set<UUID> = []
    @State private var showingAddProfile = false
    @State private var showingImportProfiles = false
    @State private var showingSettings = false
    @State private var showingInstagramLogin = false
    @State private var showingDeleteConfirmation = false
    @State private var pendingDeleteIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var sortOption: ProfileSortOption = .name
    @State private var sortAscending = true

    private var multiSelectedProfiles: [Profile] {
        profileStore.profiles.filter { selectedProfileIds.contains($0.id) }
    }

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
                selectedProfileIds: $selectedProfileIds,
                searchText: $searchText,
                sortOption: $sortOption,
                sortAscending: $sortAscending,
                onAdd: { showingAddProfile = true },
                onCheckAll: checkAll,
                onGoHome: { selectedProfile = nil },
                onSyncSelected: syncSelected,
                onRefreshSelected: refreshSelected,
                onDeleteSelected: { ids in
                    pendingDeleteIds = ids
                    showingDeleteConfirmation = true
                },
                onSetSchedule: setSchedule
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if !selectedProfileIds.isEmpty {
                MultiSelectionDetailView(
                    profiles: multiSelectedProfiles,
                    onSync: { syncSelected(selectedProfileIds) },
                    onRefresh: { refreshSelected(selectedProfileIds) },
                    onClearSelection: { selectedProfileIds.removeAll() }
                )
            } else if let profile = selectedProfile {
                ProfileDetailView(
                    profile: binding(for: profile),
                    onDelete: { selectedProfile = nil },
                    onRefresh: { refreshProfile(profile) }
                )
            } else {
                HomeView()
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .sheet(isPresented: $showingAddProfile) {
            AddProfileView { profile, startSync in
                profileStore.addProfile(profile)
                selectedProfile = profile
                if startSync {
                    DownloadManager.shared.checkProfile(profile, profileStore: profileStore)
                }
            }
        }
        .sheet(isPresented: $showingImportProfiles) {
            ImportProfilesView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    selectedProfile = nil
                    selectedProfileIds.removeAll()
                }) {
                    Image(systemName: "house")
                }
                .help("Home (\u{21E7}\u{2318}H)")

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingInstagramLogin) {
            InstagramLoginView()
        }
        .alert("Remove Profiles", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingDeleteIds.removeAll()
            }
            Button("Keep Files", role: .destructive) {
                deleteProfiles(pendingDeleteIds, deleteFiles: false)
            }
            Button("Delete Files", role: .destructive) {
                deleteProfiles(pendingDeleteIds, deleteFiles: true)
            }
        } message: {
            let count = pendingDeleteIds.count
            let names = pendingDeleteIds.compactMap { id in
                profileStore.profiles.first(where: { $0.id == id })?.username
            }.map { "@\($0)" }.joined(separator: ", ")
            Text("Remove \(count == 1 ? names : "\(count) profiles") from your archive?\n\n\u{2022} Keep Files \u{2014} removes from the app but keeps downloaded media on disk.\n\u{2022} Delete Files \u{2014} removes from the app and deletes all downloaded media.")
        }
        .focusedSceneValue(\.selectedProfile, $selectedProfile)
        .focusedSceneValue(\.showingAddProfile, $showingAddProfile)
        .focusedSceneValue(\.showingImportProfiles, $showingImportProfiles)
        .focusedSceneValue(\.showingSettings, $showingSettings)
        .focusedSceneValue(\.checkAllAction, checkAll)
        .onReceive(NotificationCenter.default.publisher(for: .webServerOpenInstagramLogin)) { _ in
            selectedProfile = nil
            selectedProfileIds.removeAll()
            showingInstagramLogin = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .webServerOpenSettings)) { _ in
            selectedProfile = nil
            selectedProfileIds.removeAll()
            showingSettings = true
        }
    }

    // MARK: - Actions

    private func checkAll() {
        DownloadManager.shared.checkAllProfiles(profileStore: profileStore)
    }

    private func syncSelected(_ ids: Set<UUID>) {
        let profiles = profileStore.profiles.filter { ids.contains($0.id) }
        DownloadManager.shared.checkProfiles(profiles, profileStore: profileStore)
    }

    private func refreshSelected(_ ids: Set<UUID>) {
        let profiles = profileStore.profiles.filter { ids.contains($0.id) }
        DownloadManager.shared.refreshProfiles(profiles, profileStore: profileStore)
    }

    private func refreshProfile(_ profile: Profile) {
        DownloadManager.shared.refreshProfile(profile, profileStore: profileStore)
    }

    private func setSchedule(_ ids: Set<UUID>, _ hours: Int?) {
        for id in ids {
            if let idx = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                profileStore.profiles[idx].customCheckIntervalHours = hours
            }
        }
        profileStore.saveAll()
    }

    private func deleteProfiles(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                if deleteFiles {
                    profileStore.removeProfileAndFiles(profile)
                } else {
                    profileStore.removeProfile(profile)
                }
            }
        }
        pendingDeleteIds.removeAll()
        selectedProfileIds.removeAll()
        if let sel = selectedProfile, ids.contains(sel.id) {
            selectedProfile = nil
        }
    }

    private func binding(for profile: Profile) -> Binding<Profile> {
        guard let index = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return .constant(profile)
        }
        return $profileStore.profiles[index]
    }
}

struct MultiSelectionDetailView: View {
    let profiles: [Profile]
    let onSync: () -> Void
    let onRefresh: () -> Void
    let onClearSelection: () -> Void

    private var profileNames: String {
        let names = profiles.prefix(5).map { "@\($0.username)" }
        let suffix = profiles.count > names.count ? " +\(profiles.count - names.count) more" : ""
        return names.joined(separator: ", ") + suffix
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("\(profiles.count) profile\(profiles.count == 1 ? "" : "s") selected")
                    .font(.title2)
                    .fontWeight(.semibold)

                if !profiles.isEmpty {
                    Text(profileNames)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }

            HStack(spacing: 10) {
                Button(action: onSync) {
                    Label("Sync Selected", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button(action: onRefresh) {
                    Label("Refresh Selected", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)

                Button(action: onClearSelection) {
                    Label("Clear Selection", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            Text("Choose Home to return to the neutral dashboard, or click a single profile to inspect its archive.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Home view with app stats
struct HomeView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var webServer: WebServer
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var diagnostics = NetworkDiagnosticsService.shared
    @State private var showingLogin = false
    @State private var totalStorage: Int64 = 0
    @State private var totalMedia: Int = 0

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

            if diagnostics.snapshot.shouldWarnUser {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: diagnostics.snapshot.level == .error ? "wifi.exclamationmark" : "network.badge.shield.half.filled")
                            .foregroundColor(diagnostics.snapshot.level == .error ? .red : .orange)
                        Text(diagnostics.snapshot.title)
                            .font(.system(size: 13, weight: .semibold))
                    }

                    Text(diagnostics.snapshot.summary)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)

                    if let recommendation = diagnostics.snapshot.recommendation {
                        Text(recommendation)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: 520, alignment: .leading)
                .background((diagnostics.snapshot.level == .error ? Color.red : Color.orange).opacity(0.08))
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
                        value: formattedCount(totalMedia),
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
        .onAppear {
            calculateStorage()
            totalMedia = DownloadManager.shared.totalDownloaded
            diagnostics.refreshIfStale()
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

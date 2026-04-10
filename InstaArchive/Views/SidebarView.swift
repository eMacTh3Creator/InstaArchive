import SwiftUI

/// Sort options for the profile list
enum ProfileSortOption: String, CaseIterable {
    case name = "Name"
    case dateAdded = "Date Added"
    case lastChecked = "Last Checked"
    case lastNewContent = "Last Updated"
    case itemCount = "Item Count"
}

/// Sidebar listing all tracked profiles with multi-select, sort, and context menus.
/// Does NOT observe DownloadManager — uses a polling timer for status updates
/// to avoid triggering 180-row re-renders on every state change.
struct SidebarView: View {
    let profiles: [Profile]
    @Binding var selectedProfile: Profile?
    @Binding var selectedProfileIds: Set<UUID>
    @Binding var searchText: String
    @Binding var sortOption: ProfileSortOption
    @Binding var sortAscending: Bool
    let onAdd: () -> Void
    let onCheckAll: () -> Void
    let onGoHome: () -> Void
    let onSyncSelected: (Set<UUID>) -> Void
    let onRefreshSelected: (Set<UUID>) -> Void
    let onDeleteSelected: (Set<UUID>) -> Void
    let onSetSchedule: (Set<UUID>, Int?) -> Void

    @EnvironmentObject var profileStore: ProfileStore

    // Polled status snapshot — updated every 2 seconds, NOT driven by objectWillChange
    @State private var statuses: [String: DownloadStatus] = [:]
    @State private var pollTimer: Timer?

    private var sortedProfiles: [Profile] {
        let sorted: [Profile]
        switch sortOption {
        case .name:
            sorted = profiles.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == (sortAscending ? .orderedAscending : .orderedDescending) }
        case .dateAdded:
            sorted = profiles.sorted { sortAscending ? $0.dateAdded < $1.dateAdded : $0.dateAdded > $1.dateAdded }
        case .lastChecked:
            sorted = profiles.sorted {
                let d0 = $0.lastChecked ?? .distantPast
                let d1 = $1.lastChecked ?? .distantPast
                return sortAscending ? d0 < d1 : d0 > d1
            }
        case .lastNewContent:
            sorted = profiles.sorted {
                let d0 = $0.lastNewContent ?? .distantPast
                let d1 = $1.lastNewContent ?? .distantPast
                return sortAscending ? d0 < d1 : d0 > d1
            }
        case .itemCount:
            sorted = profiles.sorted { sortAscending ? $0.totalDownloaded < $1.totalDownloaded : $0.totalDownloaded > $1.totalDownloaded }
        }
        return sorted
    }

    var body: some View {
        VStack(spacing: 0) {
            // Home button
            Button(action: {
                onGoHome()
                selectedProfileIds.removeAll()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 12))
                    Text("Home")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(selectedProfile == nil && selectedProfileIds.isEmpty ? .accentColor : .primary)
            .background(selectedProfile == nil && selectedProfileIds.isEmpty ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Header
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Add Profile")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search profiles...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            // Sort bar
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Picker("", selection: $sortOption) {
                    ForEach(ProfileSortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.mini)
                .frame(maxWidth: .infinity)
                Button(action: { sortAscending.toggle() }) {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(sortAscending ? "Ascending" : "Descending")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            // Multi-select action bar
            if !selectedProfileIds.isEmpty {
                HStack(spacing: 6) {
                    Text("\(selectedProfileIds.count) selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { onSyncSelected(selectedProfileIds) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Sync Selected")
                    Button(action: { selectedProfileIds.removeAll() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Selection")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()

            // Profile list
            if profiles.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundColor(.secondary)
                    Text("No profiles yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Add Profile", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedProfiles) { profile in
                            let status = statuses[profile.username] ?? .idle
                            ProfileRowView(
                                profile: profile,
                                status: status,
                                isSelected: selectedProfile?.id == profile.id,
                                isMultiSelected: selectedProfileIds.contains(profile.id),
                                onSkip: { DownloadManager.shared.skipProfile(profile.username) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) {
                                    if selectedProfileIds.contains(profile.id) {
                                        selectedProfileIds.remove(profile.id)
                                    } else {
                                        selectedProfileIds.insert(profile.id)
                                    }
                                } else if NSEvent.modifierFlags.contains(.shift), let current = selectedProfile {
                                    let list = sortedProfiles
                                    if let startIdx = list.firstIndex(where: { $0.id == current.id }),
                                       let endIdx = list.firstIndex(where: { $0.id == profile.id }) {
                                        let range = min(startIdx, endIdx)...max(startIdx, endIdx)
                                        for i in range {
                                            selectedProfileIds.insert(list[i].id)
                                        }
                                    }
                                } else {
                                    selectedProfile = profile
                                    selectedProfileIds.removeAll()
                                }
                            }
                            .contextMenu {
                                profileContextMenu(for: profile)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Bottom bar — lightweight, polls on its own timer
            SidebarBottomBar(
                profileCount: profiles.count,
                onCheckAll: onCheckAll
            )
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Status Polling

    private func startPolling() {
        refreshStatuses()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refreshStatuses() }
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshStatuses() {
        let newStatuses = DownloadManager.shared.profileStatuses
        if newStatuses != statuses {
            statuses = newStatuses
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func profileContextMenu(for profile: Profile) -> some View {
        let isMulti = selectedProfileIds.count > 1 && selectedProfileIds.contains(profile.id)
        let targetIds = isMulti ? selectedProfileIds : [profile.id]
        let label = isMulti ? "\(targetIds.count) profiles" : "@\(profile.username)"

        Button(action: { onSyncSelected(targetIds) }) {
            Label("Sync \(label)", systemImage: "arrow.clockwise")
        }

        Button(action: { onRefreshSelected(targetIds) }) {
            Label("Refresh \(label)", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Menu("Set Schedule") {
            Button("Follow Global") { onSetSchedule(targetIds, nil) }
            Divider()
            Button("Every 1h") { onSetSchedule(targetIds, 1) }
            Button("Every 6h") { onSetSchedule(targetIds, 6) }
            Button("Every 12h") { onSetSchedule(targetIds, 12) }
            Button("Every 24h") { onSetSchedule(targetIds, 24) }
            Button("Every 48h") { onSetSchedule(targetIds, 48) }
            Button("Every 7d") { onSetSchedule(targetIds, 168) }
        }

        Button(action: {
            togglePause(targetIds)
        }) {
            let allActive = targetIds.allSatisfy { id in
                profileStore.profiles.first(where: { $0.id == id })?.isActive ?? false
            }
            Label(allActive ? "Pause \(label)" : "Resume \(label)",
                  systemImage: allActive ? "pause.circle" : "play.circle")
        }

        Divider()

        Button(action: { onDeleteSelected(targetIds) }) {
            Label("Remove \(label)", systemImage: "trash")
        }
    }

    private func togglePause(_ ids: Set<UUID>) {
        for id in ids {
            if let idx = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                profileStore.profiles[idx].isActive.toggle()
            }
        }
        profileStore.saveAll()
    }
}

/// A single profile row — pure value parameters, no observation.
struct ProfileRowView: View {
    let profile: Profile
    let status: DownloadStatus
    let isSelected: Bool
    let isMultiSelected: Bool
    let onSkip: () -> Void

    private var isActive: Bool {
        if case .checking = status { return true }
        if case .downloading = status { return true }
        return false
    }

    var statusIcon: some View {
        Group {
            switch status {
            case .idle:
                Circle()
                    .fill(profile.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .downloading(let progress):
                CircularProgressView(progress: progress)
                    .frame(width: 14, height: 14)
            case .completed(let newItems):
                Image(systemName: newItems > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.system(size: 11))
            case .skipped:
                Image(systemName: "forward.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                    .help(message)
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if isMultiSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text(String(profile.username.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(profile.username)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let lastChecked = profile.lastChecked {
                    Text(lastChecked, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("Never checked")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isActive {
                Button(action: onSkip) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Skip this profile")
            }
            statusIcon
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected ? Color.accentColor.opacity(0.15) :
                    isMultiSelected ? Color.accentColor.opacity(0.08) :
                    Color.clear
                )
        )
        .padding(.horizontal, 6)
    }
}

/// Bottom bar — polls DownloadManager on its own timer, independent of view hierarchy.
struct SidebarBottomBar: View {
    let profileCount: Int
    let onCheckAll: () -> Void

    @State private var isRunning = false
    @State private var activityText: String = ""
    @State private var activeCount: Int = 0
    @State private var pollTimer: Timer?

    var body: some View {
        HStack {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activityText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if activeCount > 1 {
                        Text("\(activeCount) profiles active")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            } else {
                Text("\(profileCount) profile\(profileCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isRunning {
                Button(action: { DownloadManager.shared.stopAll() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop All Downloads")
            }
            Button(action: onCheckAll) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .help("Check All Profiles")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        let dm = DownloadManager.shared
        isRunning = dm.isRunning
        activityText = dm.currentActivity
        activeCount = dm.activeUsernames.count
    }
}

/// Tiny circular progress indicator
struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

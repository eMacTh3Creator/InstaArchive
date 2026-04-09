import SwiftUI

/// Sidebar listing all tracked profiles
struct SidebarView: View {
    let profiles: [Profile]
    @Binding var selectedProfile: Profile?
    @Binding var searchText: String
    let onAdd: () -> Void
    let onCheckAll: () -> Void
    let onGoHome: () -> Void

    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        VStack(spacing: 0) {
            // Home button
            Button(action: onGoHome) {
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
            .foregroundColor(selectedProfile == nil ? .accentColor : .primary)
            .background(selectedProfile == nil ? Color.accentColor.opacity(0.1) : Color.clear)
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
            .padding(.bottom, 8)

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
                List(selection: $selectedProfile) {
                    ForEach(profiles) { profile in
                        ProfileRowView(profile: profile)
                            .tag(profile)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Bottom bar
            HStack {
                if downloadManager.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(downloadManager.currentActivity)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if downloadManager.activeUsernames.count > 1 {
                            Text("\(downloadManager.activeUsernames.count) profiles active")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                } else {
                    Text("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if downloadManager.isRunning {
                    Button(action: { downloadManager.stopAll() }) {
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
                .disabled(downloadManager.isRunning)
                .help("Check All Profiles")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// A single profile row in the sidebar
struct ProfileRowView: View {
    let profile: Profile
    @EnvironmentObject var downloadManager: DownloadManager

    private var isActive: Bool {
        let status = downloadManager.profileStatuses[profile.username] ?? .idle
        if case .checking = status { return true }
        if case .downloading = status { return true }
        return false
    }

    var statusIcon: some View {
        Group {
            switch downloadManager.profileStatuses[profile.username] ?? .idle {
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
            // Profile pic placeholder
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
                Button(action: { downloadManager.skipProfile(profile.username) }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Skip this profile")
            }
            statusIcon
        }
        .padding(.vertical, 2)
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

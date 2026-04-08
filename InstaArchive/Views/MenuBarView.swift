import SwiftUI

/// Menu bar extra view showing quick status and actions
struct MenuBarView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var downloadManager: DownloadManager
    @ObservedObject private var settings = AppSettings.shared
    @Binding var showMainWindow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 13, weight: .semibold))
                Text("InstaArchive")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if downloadManager.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Status
            if downloadManager.isRunning {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text(downloadManager.currentActivity)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("\(profileStore.profiles.count) profiles tracked")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(downloadManager.totalDownloaded) items archived")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            Divider()

            // Recent profiles
            if !profileStore.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(profileStore.profiles.prefix(5)) { profile in
                        menuBarProfileRow(profile)
                    }
                }

                if profileStore.profiles.count > 5 {
                    Text("+ \(profileStore.profiles.count - 5) more")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }

                Divider()
            }

            // Actions
            VStack(alignment: .leading, spacing: 0) {
                menuBarButton("Check All Now", icon: "arrow.clockwise") {
                    downloadManager.checkAllProfiles(profileStore: profileStore)
                }
                .disabled(downloadManager.isRunning)

                menuBarButton("Open Archive Folder", icon: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                }

                menuBarButton("Open InstaArchive", icon: "macwindow") {
                    showMainWindow = true
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Divider()

            menuBarButton("Quit InstaArchive", icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: 280)
    }

    private func menuBarProfileRow(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(profile.isActive ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Text("@\(profile.username)")
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            if let status = downloadManager.profileStatuses[profile.username] {
                switch status {
                case .completed(let count) where count > 0:
                    Text("+\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func menuBarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

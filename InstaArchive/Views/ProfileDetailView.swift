import SwiftUI

/// Detail view showing a profile's archive status and downloaded media
struct ProfileDetailView: View {
    @Binding var profile: Profile
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var profileStore: ProfileStore
    @State private var selectedMediaType: MediaType? = nil
    @State private var showingDeleteConfirmation = false
    @State private var cachedItems: [MediaItem] = []
    @State private var lastRefreshId: String = ""
    @State private var profileStorageSize: Int64 = 0
    var onDelete: (() -> Void)? = nil

    /// Single query, cached in @State so SwiftUI doesn't re-filter 20K items on every body eval
    private func refreshItemsIfNeeded() {
        let refreshId = "\(profile.username)-\(downloadManager.totalDownloaded)"
        guard refreshId != lastRefreshId else { return }
        lastRefreshId = refreshId
        cachedItems = downloadManager.mediaItems(for: profile.username)
        calculateStorageSize()
    }

    private func calculateStorageSize() {
        let username = profile.username
        Task.detached(priority: .utility) {
            let size = StorageManager.shared.downloadedSize(for: username)
            await MainActor.run { profileStorageSize = size }
        }
    }

    private var filteredItems: [MediaItem] {
        if let type = selectedMediaType {
            return cachedItems.filter { $0.mediaType == type }
        }
        return cachedItems
    }

    private var mediaTypeCounts: [(MediaType, Int)] {
        return MediaType.allCases.compactMap { type in
            let count = cachedItems.filter { $0.mediaType == type }.count
            return count > 0 ? (type, count) : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Profile header
            profileHeader

            // Error banner (if last check failed)
            if case .error(let message) = downloadManager.profileStatuses[profile.username] ?? .idle {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry") { checkNow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button(action: { downloadManager.clearStatus(for: profile.username) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()

            // Filter bar
            filterBar

            Divider()

            // Media grid
            if filteredItems.isEmpty {
                emptyMediaView
            } else {
                mediaGrid
            }
        }
        .onAppear { refreshItemsIfNeeded() }
        .onChange(of: profile.username) { _ in
            lastRefreshId = ""
            refreshItemsIfNeeded()
        }
        .onChange(of: downloadManager.totalDownloaded) { _ in refreshItemsIfNeeded() }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        HStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                Text(String(profile.username.prefix(1)).uppercased())
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("@\(profile.username)")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if !profile.isActive {
                        Text("PAUSED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

                if !profile.displayName.isEmpty && profile.displayName != profile.username {
                    Text(profile.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    Label("\(profile.totalDownloaded) items", systemImage: "square.and.arrow.down")
                    if let lastChecked = profile.lastChecked {
                        Label {
                            Text(lastChecked, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                    if profileStorageSize > 0 {
                        Label(StorageManager.formatBytes(profileStorageSize), systemImage: "externaldrive")
                    }
                    Label(scheduleLabel, systemImage: "calendar.badge.clock")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if isDownloadingThisProfile {
                        Button(action: skipThisProfile) {
                            Label("Skip", systemImage: "forward.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Skip this profile's download")
                    } else {
                        Button(action: checkNow) {
                            Label("Check Now", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button(action: openInFinder) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open in Finder")

                    Button(action: openInBrowser) {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open on Instagram")
                }

                HStack(spacing: 8) {
                    // Per-profile schedule picker
                    Picker("", selection: Binding<Int>(
                        get: { profile.customCheckIntervalHours ?? -1 },
                        set: { newValue in
                            profile.customCheckIntervalHours = newValue == -1 ? nil : newValue
                            profileStore.saveAll()
                        }
                    )) {
                        Text("Follow Global").tag(-1)
                        Divider()
                        Text("Every 1h").tag(1)
                        Text("Every 6h").tag(6)
                        Text("Every 12h").tag(12)
                        Text("Every 24h").tag(24)
                        Text("Every 48h").tag(48)
                        Text("Every 7d").tag(168)
                    }
                    .frame(width: 140)
                    .controlSize(.small)
                    .help("Check schedule for this profile")

                    Button(action: toggleActive) {
                        Label(
                            profile.isActive ? "Pause" : "Resume",
                            systemImage: profile.isActive ? "pause.circle" : "play.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { showingDeleteConfirmation = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove Profile")
                }
            }
        }
        .padding(20)
        .alert("Remove Profile", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Keep Files", role: .destructive) {
                profileStore.removeProfile(profile)
                onDelete?()
            }
            Button("Delete Files", role: .destructive) {
                profileStore.removeProfileAndFiles(profile)
                onDelete?()
            }
        } message: {
            Text("Remove @\(profile.username) from your archive?\n\n• Keep Files — removes from the app but keeps downloaded media on disk.\n• Delete Files — removes from the app and deletes all downloaded media.")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", count: cachedItems.count,
                           isSelected: selectedMediaType == nil) {
                    selectedMediaType = nil
                }

                ForEach(mediaTypeCounts, id: \.0) { type, count in
                    FilterChip(title: type.rawValue, count: count,
                               isSelected: selectedMediaType == type) {
                        selectedMediaType = (selectedMediaType == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Media Grid

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 8)
            ], spacing: 8) {
                ForEach(filteredItems) { item in
                    MediaThumbnailView(item: item)
                }
            }
            .padding(16)
        }
    }

    private var emptyMediaView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(.secondary)
            Text("No media downloaded yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if isDownloadingThisProfile {
                Button("Skip", action: skipThisProfile)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Check Now", action: checkNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var scheduleLabel: String {
        if let custom = profile.customCheckIntervalHours {
            switch custom {
            case 1: return "Every 1h"
            case 6: return "Every 6h"
            case 12: return "Every 12h"
            case 24: return "Every 24h"
            case 48: return "Every 48h"
            case 168: return "Every 7d"
            default: return "Every \(custom)h"
            }
        }
        return "Global (\(AppSettings.shared.checkIntervalHours)h)"
    }

    private var isDownloadingThisProfile: Bool {
        let status = downloadManager.profileStatuses[profile.username] ?? .idle
        if case .checking = status { return true }
        if case .downloading = status { return true }
        return false
    }

    private func checkNow() {
        downloadManager.checkProfile(profile, profileStore: profileStore)
    }

    private func skipThisProfile() {
        downloadManager.skipProfile(profile.username)
    }

    private func openInFinder() {
        let url = AppSettings.shared.profileDirectory(for: profile.username)
        StorageManager.shared.ensureDirectoryExists(url)
        NSWorkspace.shared.open(url)
    }

    private func openInBrowser() {
        if let url = URL(string: "https://www.instagram.com/\(profile.username)/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleActive() {
        profile.isActive.toggle()
        profileStore.saveAll()
    }
}

/// Filter chip button
struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.3) : Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Thumbnail view for a single media item in the grid.
/// Uses async loading + ThumbnailCache for smooth scrolling at scale.
struct MediaThumbnailView: View {
    let item: MediaItem
    @State private var thumbnail: NSImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .aspectRatio(1, contentMode: .fit)

                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else if item.mediaType.isVideo || item.localPath == nil {
                    // Video or missing file placeholder
                    VStack(spacing: 6) {
                        Image(systemName: item.mediaType.iconName)
                            .font(.system(size: 24, weight: .thin))
                            .foregroundColor(.secondary)
                        Text(item.mediaType.rawValue)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    // Loading placeholder
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }

                // Type badge
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: item.mediaType.iconName)
                            .font(.system(size: 9, weight: .bold))
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                    }
                    Spacer()
                }
                .padding(6)
            }
            .cornerRadius(8)
            .clipped()

            // Caption/info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timestamp, style: .date)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if let size = item.fileSize {
                    Text(StorageManager.formatBytes(size))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
        .onTapGesture(count: 2) {
            if let path = item.localPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadThumbnail() {
        guard !item.mediaType.isVideo, item.localPath != nil else { return }

        // Check memory cache synchronously first — no async overhead
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: item.instagramId) {
            thumbnail = cached
            return
        }

        // Load async
        loadTask = Task {
            let image = await ThumbnailCache.shared.thumbnail(for: item)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.thumbnail = image
            }
        }
    }
}

// MARK: - Helpers

extension MediaType {
    var iconName: String {
        switch self {
        case .post: return "photo"
        case .reel: return "film"
        case .video: return "video"
        case .highlight: return "star.circle"
        case .story: return "clock.circle"
        case .profilePic: return "person.circle"
        }
    }

    var isVideo: Bool {
        switch self {
        case .reel, .video: return true
        default: return false
        }
    }
}

import SwiftUI

/// Sheet for adding a new Instagram profile to the queue
struct AddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var profileInfo: InstagramProfileInfo?
    @State private var syncPeriod: Int = 0  // 0 = all time

    let onAdd: (Profile, Bool) -> Void  // (profile, startSync)

    var cleanUsername: String {
        var clean = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle pasted URLs
        if clean.contains("instagram.com/") {
            if let range = clean.range(of: "instagram.com/") {
                clean = String(clean[range.upperBound...])
                clean = clean.components(separatedBy: CharacterSet(charactersIn: "/?")).first ?? clean
            }
        }
        // Remove @ prefix
        if clean.hasPrefix("@") {
            clean = String(clean.dropFirst())
        }
        return clean.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Profile")
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

            // Input
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instagram Username")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "at")
                            .foregroundColor(.secondary)
                        TextField("username or profile URL", text: $username)
                            .textFieldStyle(.plain)
                            .onSubmit { lookupProfile() }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    Text("You can paste a username, @handle, or full profile URL")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                }

                // Preview card
                if let info = profileInfo {
                    profilePreview(info)

                    // Sync period picker
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sync posts from")
                                .font(.system(size: 13))
                            Picker("", selection: $syncPeriod) {
                                Text("All time").tag(0)
                                Text("Last 1 month").tag(1)
                                Text("Last 3 months").tag(3)
                                Text("Last 6 months").tag(6)
                                Text("Last 1 year").tag(12)
                                Text("Last 2 years").tag(24)
                            }
                            .frame(width: 150)
                        }
                        Text("Limits the initial download to recent posts. Stories and highlights are always synced.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(20)

            Spacer()

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                if profileInfo == nil {
                    Button("Look Up") { lookupProfile() }
                        .buttonStyle(.borderedProminent)
                        .disabled(cleanUsername.isEmpty || isLoading)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Add to Queue") { addProfile(startSync: false) }
                        .buttonStyle(.bordered)

                    Button("Add & Sync") { addProfile(startSync: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 420, height: 460)
    }

    private func profilePreview(_ info: InstagramProfileInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Text(String(info.username.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("@\(info.username)")
                    .font(.system(size: 14, weight: .semibold))
                if !info.fullName.isEmpty {
                    Text(info.fullName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    Text("\(info.postCount) posts")
                    Text("\(info.followerCount) followers")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            if info.isPrivate {
                VStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                    Text("Private")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            } else {
                VStack {
                    Image(systemName: "globe")
                        .foregroundColor(.green)
                    Text("Public")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func lookupProfile() {
        guard !cleanUsername.isEmpty else { return }
        errorMessage = nil
        profileInfo = nil
        isLoading = true

        Task {
            do {
                let info = try await InstagramService.shared.fetchProfileInfo(username: cleanUsername)
                await MainActor.run {
                    if info.isPrivate {
                        errorMessage = "This profile is private. Only public profiles can be archived."
                    }
                    profileInfo = info
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func addProfile(startSync: Bool) {
        guard let info = profileInfo else { return }

        let profile = Profile(
            username: info.username,
            displayName: info.fullName,
            profilePicURL: info.profilePicURL,
            bio: info.biography,
            syncSinceMonths: syncPeriod > 0 ? syncPeriod : nil
        )
        onAdd(profile, startSync)
        dismiss()
    }
}

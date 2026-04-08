import SwiftUI

/// First-launch onboarding to pick a download folder
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedPath: String = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 20)

            Text("Welcome to InstaArchive")
                .font(.title)
                .fontWeight(.semibold)

            Text("Archive public Instagram profiles automatically.\nChoose where to save your downloads.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.bottom, 24)

            // Folder picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Download Location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    Text(selectedPath.isEmpty ? settings.downloadPath : selectedPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose...") {
                        chooseFolder()
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .frame(maxWidth: 400)

            Spacer()

            // Continue button
            Button(action: {
                if !selectedPath.isEmpty {
                    settings.downloadPath = selectedPath
                }
                settings.hasCompletedOnboarding = true
                onComplete()
            }) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(width: 500, height: 420)
        .onAppear {
            selectedPath = settings.downloadPath
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
            selectedPath = url.path
        }
    }
}

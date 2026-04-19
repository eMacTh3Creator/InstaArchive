import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ImportProfilesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var selectedFileName: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Profiles")
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

            VStack(alignment: .leading, spacing: 18) {
                Text("Drop an InstaArchive export from Finder, or browse to it manually.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                dropZone

                HStack(spacing: 10) {
                    Button("Browse...") {
                        browseForFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)

                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Importing...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if let fileName = selectedFileName {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.accentColor)
                        Text(fileName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                if let statusMessage {
                    messageRow(
                        systemImage: "checkmark.circle.fill",
                        tint: .green,
                        text: statusMessage
                    )
                }

                if let errorMessage {
                    messageRow(
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: errorMessage
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 360)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(isTargeted ? .accentColor : .secondary)

                Text("Drop a profile export here")
                    .font(.system(size: 15, weight: .semibold))

                Text("JSON exports from Finder will import immediately.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(24)
        }
        .frame(height: 180)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func messageRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Profiles"
        panel.message = "Choose an InstaArchive profile export."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importProfiles(from: url)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            errorMessage = "Drop a file from Finder to import profiles."
            statusMessage = nil
            return false
        }

        loadFileURL(from: provider) { url in
            guard let url else {
                DispatchQueue.main.async {
                    errorMessage = "That file could not be read. Try Browse if Finder drop keeps failing."
                    statusMessage = nil
                }
                return
            }

            DispatchQueue.main.async {
                importProfiles(from: url)
            }
        }

        return true
    }

    private func loadFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = item as? URL {
                completion(url)
                return
            }

            if let url = item as? NSURL {
                completion(url as URL)
                return
            }

            if let data = item as? Data,
               let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? {
                completion(url)
                return
            }

            if let text = item as? String,
               let url = URL(string: text) {
                completion(url)
                return
            }

            completion(nil)
        }
    }

    private func importProfiles(from url: URL) {
        isImporting = true
        selectedFileName = url.lastPathComponent
        statusMessage = nil
        errorMessage = nil

        let accessedSecurityScope = url.startAccessingSecurityScopedResource()

        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let added = try profileStore.importProfiles(from: url)
            if added == 0 {
                statusMessage = "Import finished. No new profiles were found in this file."
            } else if added == 1 {
                statusMessage = "Import finished. Added 1 new profile."
            } else {
                statusMessage = "Import finished. Added \(added) new profiles."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
    }
}

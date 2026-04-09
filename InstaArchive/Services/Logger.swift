import Foundation

/// Simple rotating logger that writes to ~/Library/Logs/InstaArchive/
/// Keeps the last `maxEntries` log entries to avoid filling up disk.
final class Logger {
    static let shared = Logger()

    let logDirectory: URL
    private let logFileURL: URL
    private let maxEntries = 20
    private let lock = NSLock()
    private var entries: [String] = []

    private init() {
        let logsRoot = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("InstaArchive")
        logDirectory = logsRoot

        do {
            try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        } catch {
            print("[Logger] Failed to create log directory: \(error)")
        }

        logFileURL = logsRoot.appendingPathComponent("instaarchive.log")

        // Load existing entries
        if let data = try? Data(contentsOf: logFileURL),
           let content = String(data: data, encoding: .utf8) {
            entries = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Trim to maxEntries on load
            if entries.count > maxEntries {
                entries = Array(entries.suffix(maxEntries))
            }
        }
    }

    // MARK: - Public API

    func info(_ message: String, context: String = "") {
        append(level: "INFO", message: message, context: context)
    }

    func warn(_ message: String, context: String = "") {
        append(level: "WARN", message: message, context: context)
    }

    func error(_ message: String, context: String = "") {
        append(level: "ERROR", message: message, context: context)
    }

    /// Return the most recent log entries (newest first)
    func recentEntries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    // MARK: - Private

    private func append(level: String, message: String, context: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let ctx = context.isEmpty ? "" : " [\(context)]"
        let line = "\(timestamp) \(level)\(ctx) \(message)"

        // Also print to console for debugging
        print("[InstaArchive] \(level)\(ctx) \(message)")

        lock.lock()
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let snapshot = entries
        lock.unlock()

        // Write to disk asynchronously
        DispatchQueue.global(qos: .utility).async { [logFileURL] in
            let content = snapshot.joined(separator: "\n") + "\n"
            try? content.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }
}

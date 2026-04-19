import Foundation

/// Rolling-file logger that writes to ~/Library/Logs/InstaArchive/instaarchive.log.
///
/// Replaces the previous 20-entry ring buffer with a real rolling log so historic
/// troubleshooting is possible. Design:
///
/// - Opens a `FileHandle` in append mode at init so each write is O(1) instead of
///   rewriting the entire file. The old "ring buffer rewritten on every call"
///   approach made the log quadratic in entries-per-session and, worse, limited
///   history to the last 20 lines — which ate download-phase diagnostics before
///   they could be seen.
/// - Rotates when the file exceeds `maxFileSize` (25 MB): current `.log` is moved
///   through a numbered archive chain (`.log.1` ... `.log.5`) and a fresh empty
///   `.log` is opened. So at most 150 MB on disk total.
/// - Size check runs every write — cheap because `FileHandle.offsetInFile` is an
///   in-memory cursor, no stat() call needed.
/// - Disk writes go through a serial dispatch queue so callers on any thread never
///   block waiting for I/O.
/// - `NSLock` protects the in-memory cursor/handle so the rotation path can't race
///   with a concurrent append.
final class Logger {
    static let shared = Logger()

    let logDirectory: URL
    private let logFileURL: URL
    private let rotatedLogFileBaseURL: URL

    /// Rotate when the active log exceeds this size (approximately).
    /// 25 MB with 5 archived generations keeps far more sync history available
    /// for troubleshooting while still capping disk usage.
    private let maxFileSize: UInt64 = 25 * 1024 * 1024
    private let maxArchiveCount = 5

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.instaarchive.logger.write", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileSize: UInt64 = 0

    private init() {
        let logsRoot = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("InstaArchive")
        logDirectory = logsRoot
        logFileURL = logsRoot.appendingPathComponent("instaarchive.log")
        rotatedLogFileBaseURL = logsRoot.appendingPathComponent("instaarchive.log")

        do {
            try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        } catch {
            print("[Logger] Failed to create log directory: \(error)")
        }

        openHandle()
    }

    deinit {
        try? fileHandle?.close()
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

    // MARK: - Handle management

    /// Open (or re-open) the active log file in append mode and capture its
    /// current size so subsequent rotation decisions are accurate.
    private func openHandle() {
        // Ensure the file exists — FileHandle(forWritingTo:) will fail otherwise.
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            handle.seekToEndOfFile()
            fileHandle = handle
            currentFileSize = handle.offsetInFile
        } catch {
            print("[Logger] Failed to open log file handle: \(error)")
            fileHandle = nil
            currentFileSize = 0
        }
    }

    /// Rotate the active log through `.log.1` ... `.log.N`, then reopen a fresh
    /// empty `.log`. Must be called with
    /// `lock` held.
    private func rotateIfNeeded_locked() {
        guard currentFileSize >= maxFileSize else { return }

        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        for index in stride(from: maxArchiveCount, through: 1, by: -1) {
            let sourceURL = archivedLogURL(index: index)
            let destinationURL = archivedLogURL(index: index + 1)
            if index == maxArchiveCount {
                try? fm.removeItem(at: sourceURL)
                continue
            }
            if fm.fileExists(atPath: sourceURL.path) {
                try? fm.removeItem(at: destinationURL)
                try? fm.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        if fm.fileExists(atPath: logFileURL.path) {
            try? fm.removeItem(at: archivedLogURL(index: 1))
            try? fm.moveItem(at: logFileURL, to: archivedLogURL(index: 1))
        }

        openHandle()
    }

    private func archivedLogURL(index: Int) -> URL {
        rotatedLogFileBaseURL.deletingPathExtension()
            .appendingPathExtension("log.\(index)")
    }

    // MARK: - Private

    private func append(level: String, message: String, context: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let ctx = context.isEmpty ? "" : " [\(context)]"
        let line = "\(timestamp) \(level)\(ctx) \(message)\n"

        // Mirror to stdout so `Console.app` / Xcode debug view still shows everything
        // even when the file handle is unavailable.
        print("[InstaArchive] \(level)\(ctx) \(message)")

        guard let data = line.data(using: .utf8) else { return }

        // Hop to the serial write queue so we never block the caller on disk I/O.
        // The lock serializes access to the handle and size cursor — writeQueue
        // is serial, but `openHandle`/`rotateIfNeeded` mutate shared state and
        // could race with other code that touches `fileHandle` in the future.
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            guard let handle = self.fileHandle else {
                // Handle was never opened or was closed after a rotation failure;
                // fall back to a best-effort atomic write so we don't silently
                // drop log lines.
                _ = try? data.write(to: self.logFileURL, options: .atomic)
                return
            }

            do {
                try handle.write(contentsOf: data)
                self.currentFileSize += UInt64(data.count)
            } catch {
                // If the underlying file vanished or the descriptor went bad,
                // try to recover by reopening once.
                self.openHandle()
                if let handle = self.fileHandle {
                    try? handle.write(contentsOf: data)
                    self.currentFileSize += UInt64(data.count)
                }
            }

            self.rotateIfNeeded_locked()
        }
    }
}

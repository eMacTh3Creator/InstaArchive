import AppKit
import SwiftUI

/// High-performance thumbnail cache with LRU eviction and async loading.
/// Generates small thumbnails from full-res images, caches in memory + disk.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// Thumbnail size in points (rendered at 2x for Retina)
    private let thumbSize: CGFloat = 200
    private let scale: CGFloat = 2.0

    /// In-memory LRU cache
    private let memoryCache = NSCache<NSString, NSImage>()
    private let maxMemoryCount = 500 // keep up to 500 thumbnails in RAM (~50MB)

    /// Disk cache directory
    private let diskCacheURL: URL

    /// Track in-flight generation to avoid duplicate work
    private var inFlight: Set<String> = []
    private let lock = NSLock()

    private let fileManager = FileManager.default

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("InstaArchive/Thumbnails")
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        memoryCache.countLimit = maxMemoryCount
    }

    // MARK: - Public API

    /// Get a thumbnail synchronously if cached in memory. Returns nil if not available yet.
    func cachedThumbnail(for id: String) -> NSImage? {
        return memoryCache.object(forKey: id as NSString)
    }

    /// Load a thumbnail, generating from source if needed. Runs on a background queue.
    func thumbnail(for item: MediaItem) async -> NSImage? {
        let key = item.instagramId

        // 1. Check memory cache
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. Check disk cache
        let diskPath = diskCacheURL.appendingPathComponent("\(key).jpg")
        if let diskImage = NSImage(contentsOf: diskPath) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }

        // 3. Generate from source file
        guard let localPath = item.localPath else { return nil }

        // Skip if already generating this thumbnail
        if !tryStartGeneration(key: key) {
            // Another task is generating — wait for it
            return await waitForThumbnail(key: key, timeout: 5.0)
        }

        // Generate on a background thread (nonisolated to avoid Sendable warnings)
        let thumb: NSImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = self.generateThumbnail(from: localPath, key: key, diskPath: diskPath)
                continuation.resume(returning: result)
            }
        }

        finishGeneration(key: key)

        if let thumb = thumb {
            memoryCache.setObject(thumb, forKey: key as NSString)
        }

        return thumb
    }

    /// Synchronous lock helpers to avoid NSLock in async contexts
    private func tryStartGeneration(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight.contains(key) { return false }
        inFlight.insert(key)
        return true
    }

    private func finishGeneration(key: String) {
        lock.lock()
        inFlight.remove(key)
        lock.unlock()
    }

    /// Preload thumbnails for a batch of items (call from background)
    func preload(_ items: [MediaItem]) async {
        await withTaskGroup(of: Void.self) { group in
            // Limit concurrency to avoid overwhelming the system
            var count = 0
            for item in items {
                // Skip videos and items already cached
                if item.mediaType.isVideo { continue }
                if cachedThumbnail(for: item.instagramId) != nil { continue }

                count += 1
                if count > 50 { break } // preload at most 50 at a time

                group.addTask {
                    _ = await self.thumbnail(for: item)
                }
            }
        }
    }

    /// Clear the entire cache (memory + disk)
    func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    /// Remove cached thumbnails for a specific profile
    func clearProfile(_ username: String, items: [MediaItem]) {
        for item in items where item.profileUsername == username {
            let key = item.instagramId as NSString
            memoryCache.removeObject(forKey: key)
            let diskPath = diskCacheURL.appendingPathComponent("\(item.instagramId).jpg")
            try? fileManager.removeItem(at: diskPath)
        }
    }

    // MARK: - Private

    private func generateThumbnail(from path: String, key: String, diskPath: URL) -> NSImage? {
        let url = URL(fileURLWithPath: path)

        // Use CGImageSource for efficient thumbnail generation without loading full image
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let maxDimension = Int(thumbSize * scale)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Save to disk cache (JPEG, quality 0.7 for small file size)
        saveToDisk(nsImage, at: diskPath)

        return nsImage
    }

    private func saveToDisk(_ image: NSImage, at url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return
        }
        try? jpegData.write(to: url, options: .atomic)
    }

    private func waitForThumbnail(key: String, timeout: TimeInterval) async -> NSImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cached = memoryCache.object(forKey: key as NSString) {
                return cached
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return memoryCache.object(forKey: key as NSString)
    }
}

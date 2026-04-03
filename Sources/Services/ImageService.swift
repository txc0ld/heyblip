import Foundation
import UIKit
import SwiftData
import CryptoKit
import os.log

// MARK: - Image Service Error

enum ImageServiceError: Error, Sendable {
    case compressionFailed
    case invalidImageData
    case thumbnailGenerationFailed
    case imageTooLarge(Int)
    case cacheWriteFailed(String)
    case unsupportedFormat
}

// MARK: - Image Format

enum ImageFormat: Sendable {
    case jpeg(quality: CGFloat)
    case heif(quality: CGFloat)

    var mimeType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .heif: return "image/heif"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heif: return "heif"
        }
    }
}

// MARK: - Thumbnail Size

enum ThumbnailSize: Sendable {
    /// 64x64 for avatar thumbnails.
    case avatar
    /// 200px wide for message previews.
    case messagePreview
    /// Custom size.
    case custom(width: CGFloat, height: CGFloat)

    var dimension: CGSize {
        switch self {
        case .avatar:
            return CGSize(width: 64, height: 64)
        case .messagePreview:
            return CGSize(width: 200, height: 200)
        case .custom(let width, let height):
            return CGSize(width: width, height: height)
        }
    }
}

// MARK: - Cache Entry

private struct CacheEntry {
    let data: Data
    let size: Int
    let accessTime: Date
    let key: String
}

// MARK: - Image Service

/// Handles image compression, thumbnail generation, and LRU caching for Blip.
///
/// Features:
/// - JPEG/HEIF compression with configurable quality
/// - Thumbnail generation (64x64 for avatars, 200px for message previews)
/// - LRU cache with 500MB capacity
/// - Disk-backed cache for persistence across launches
/// - Thread-safe concurrent access
final class ImageService: @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "ImageService")

    // MARK: - Constants

    /// Maximum image size for mesh transport (500KB).
    static let maxImageSizeBytes = 500_000

    /// Default JPEG compression quality.
    static let defaultJPEGQuality: CGFloat = 0.7

    /// Maximum JPEG quality for progressive compression.
    static let maxJPEGQuality: CGFloat = 0.9

    /// Minimum JPEG quality floor.
    static let minJPEGQuality: CGFloat = 0.3

    /// LRU cache capacity in bytes (500MB).
    static let cacheCapacity = 500 * 1024 * 1024 // 500MB

    /// Maximum dimension for full-size images before downscaling.
    static let maxFullSizeDimension: CGFloat = 2048

    // MARK: - Properties

    /// Current cache usage in bytes.
    private(set) var cacheUsage: Int = 0

    // MARK: - Private State

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let cacheDirectory: URL
    private let fileManager = FileManager.default

    // MARK: - Init

    init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("com.blip.images", isDirectory: true)

        let directoryExists = FileManager.default.fileExists(atPath: cacheDirectory.path)

        if !directoryExists {
            // First launch: create directory, skip metadata scan (nothing to scan)
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                DebugLogger.emit("APP", "Created image cache directory")
            } catch {
                DebugLogger.emit("APP", "Failed to create image cache directory: \(error)", isError: true)
            }
        } else {
            // Existing cache: scan for metadata
            loadCacheMetadata()
        }
    }

    // MARK: - Compression

    /// Compress an image to fit within the mesh transport size limit.
    ///
    /// Progressively reduces quality until the image fits within `maxImageSizeBytes`.
    /// - Parameters:
    ///   - image: The source UIImage.
    ///   - format: Target format (JPEG or HEIF). Defaults to JPEG at 0.7 quality.
    /// - Returns: Compressed image data and the format used.
    func compress(image: UIImage, format: ImageFormat = .jpeg(quality: defaultJPEGQuality)) throws -> Data {
        // Downscale if necessary
        let scaled = downscaleIfNeeded(image, maxDimension: Self.maxFullSizeDimension)

        // First attempt with requested quality
        var quality: CGFloat
        switch format {
        case .jpeg(let q): quality = q
        case .heif(let q): quality = q
        }

        let compressed = compressWithFormat(scaled, format: format)
        guard var data = compressed else {
            throw ImageServiceError.compressionFailed
        }

        // Progressively reduce quality if too large
        while data.count > Self.maxImageSizeBytes && quality > Self.minJPEGQuality {
            quality -= 0.1
            let adjustedFormat: ImageFormat
            switch format {
            case .jpeg: adjustedFormat = .jpeg(quality: quality)
            case .heif: adjustedFormat = .heif(quality: quality)
            }
            if let recompressed = compressWithFormat(scaled, format: adjustedFormat) {
                data = recompressed
            } else {
                break
            }
        }

        // Final size check
        if data.count > Self.maxImageSizeBytes {
            // Try with smallest dimension
            let smaller = downscaleIfNeeded(image, maxDimension: 1024)
            if let smallerData = compressWithFormat(smaller, format: .jpeg(quality: Self.minJPEGQuality)) {
                if smallerData.count <= Self.maxImageSizeBytes {
                    return smallerData
                }
            }
            throw ImageServiceError.imageTooLarge(data.count)
        }

        return data
    }

    /// Compress raw image data.
    func compress(data: Data, format: ImageFormat = .jpeg(quality: defaultJPEGQuality)) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw ImageServiceError.invalidImageData
        }
        return try compress(image: image, format: format)
    }

    // MARK: - Thumbnail Generation

    /// Generate a thumbnail from an image.
    ///
    /// - Parameters:
    ///   - image: The source UIImage.
    ///   - size: Target thumbnail size.
    /// - Returns: JPEG-compressed thumbnail data.
    func generateThumbnail(from image: UIImage, size: ThumbnailSize) throws -> Data {
        let targetSize = size.dimension

        // Calculate aspect-fit size
        let aspectSize = aspectFitSize(for: image.size, in: targetSize)

        UIGraphicsBeginImageContextWithOptions(aspectSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: aspectSize))

        guard let thumbnail = UIGraphicsGetImageFromCurrentImageContext() else {
            throw ImageServiceError.thumbnailGenerationFailed
        }

        // Compress thumbnail with moderate quality
        let quality: CGFloat = size == .avatar ? 0.6 : 0.7
        guard let data = thumbnail.jpegData(compressionQuality: quality) else {
            throw ImageServiceError.compressionFailed
        }

        return data
    }

    /// Generate a thumbnail from raw image data.
    func generateThumbnail(from data: Data, size: ThumbnailSize) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw ImageServiceError.invalidImageData
        }
        return try generateThumbnail(from: image, size: size)
    }

    /// Generate both avatar (64x64) and preview (200px) thumbnails at once.
    func generateThumbnails(from image: UIImage) throws -> (avatar: Data, preview: Data) {
        let avatar = try generateThumbnail(from: image, size: .avatar)
        let preview = try generateThumbnail(from: image, size: .messagePreview)
        return (avatar, preview)
    }

    // MARK: - Center Crop

    /// Crop an image to a square from the center (useful for avatar creation).
    func centerCrop(image: UIImage) -> UIImage {
        let sideLength = min(image.size.width, image.size.height)
        let origin = CGPoint(
            x: (image.size.width - sideLength) / 2.0,
            y: (image.size.height - sideLength) / 2.0
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: sideLength, height: sideLength))

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Cache Operations

    /// Store image data in the LRU cache.
    func cacheImage(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        // Remove existing entry if present
        if let existing = cache[key] {
            cacheUsage -= existing.size
        }

        // Evict entries if over capacity
        while cacheUsage + data.count > Self.cacheCapacity && !cache.isEmpty {
            evictLeastRecentlyUsed()
        }

        // Store in memory cache
        let entry = CacheEntry(
            data: data,
            size: data.count,
            accessTime: Date(),
            key: key
        )
        cache[key] = entry
        cacheUsage += data.count

        // Write to disk asynchronously
        let fileURL = cacheDirectory.appendingPathComponent(key.sha256Hash)
        let logger = self.logger
        DispatchQueue.global(qos: .utility).async {
            do {
                try data.write(to: fileURL)
            } catch {
                logger.warning("Failed to write image cache to disk: \(error.localizedDescription)")
            }
        }
    }

    /// Retrieve image data from the cache.
    func cachedImage(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        // Check memory cache
        if let entry = cache[key] {
            // Update access time
            let updated = CacheEntry(
                data: entry.data,
                size: entry.size,
                accessTime: Date(),
                key: entry.key
            )
            cache[key] = updated
            return entry.data
        }

        // Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent(key.sha256Hash)
        do {
            let data = try Data(contentsOf: fileURL)
            // Promote to memory cache
            let entry = CacheEntry(data: data, size: data.count, accessTime: Date(), key: key)
            cache[key] = entry
            cacheUsage += data.count
            return data
        } catch {
            logger.warning("Failed to read image cache from disk for key \(key): \(error.localizedDescription)")
        }

        return nil
    }

    /// Remove a specific entry from the cache.
    func removeCachedImage(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        if let entry = cache.removeValue(forKey: key) {
            cacheUsage -= entry.size
        }

        let fileURL = cacheDirectory.appendingPathComponent(key.sha256Hash)
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            logger.warning("Failed to remove cached image file for key \(key): \(error.localizedDescription)")
        }
    }

    /// Clear the entire cache.
    func clearCache() {
        lock.lock()
        defer { lock.unlock() }

        cache.removeAll()
        cacheUsage = 0

        do {
            try fileManager.removeItem(at: cacheDirectory)
        } catch {
            logger.warning("Failed to remove image cache directory: \(error.localizedDescription)")
        }
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            logger.warning("Failed to recreate image cache directory: \(error.localizedDescription)")
        }
    }

    /// Get the number of cached entries.
    var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: - Private: Compression Helpers

    private func compressWithFormat(_ image: UIImage, format: ImageFormat) -> Data? {
        switch format {
        case .jpeg(let quality):
            return image.jpegData(compressionQuality: quality)
        case .heif(let quality):
            // Use CIContext for HEIF encoding
            guard let ciImage = CIImage(image: image) else { return nil }
            let context = CIContext()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            return context.heifRepresentation(
                of: ciImage,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            )
        }
    }

    private func downscaleIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let aspectSize = aspectFitSize(for: size, in: CGSize(width: maxDimension, height: maxDimension))

        UIGraphicsBeginImageContextWithOptions(aspectSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: aspectSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    private func aspectFitSize(for imageSize: CGSize, in targetSize: CGSize) -> CGSize {
        let widthRatio = targetSize.width / imageSize.width
        let heightRatio = targetSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio, 1.0) // Don't upscale
        return CGSize(
            width: floor(imageSize.width * scale),
            height: floor(imageSize.height * scale)
        )
    }

    // MARK: - Private: LRU Eviction

    private func evictLeastRecentlyUsed() {
        guard let oldest = cache.values.min(by: { $0.accessTime < $1.accessTime }) else { return }

        cache.removeValue(forKey: oldest.key)
        cacheUsage -= oldest.size

        let fileURL = cacheDirectory.appendingPathComponent(oldest.key.sha256Hash)
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            logger.warning("Failed to remove evicted cache file: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Cache Metadata

    private func loadCacheMetadata() {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            DebugLogger.emit("APP", "Cache directory does not exist, skipping metadata scan")
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            DebugLogger.emit("APP", "Failed to list image cache directory: \(error)", isError: true)
            return
        }

        var totalSize = 0
        for url in contents {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize {
                    totalSize += size
                }
            } catch {
                DebugLogger.emit("APP", "Failed to read cache file metadata: \(error)", isError: true)
            }
        }
        cacheUsage = totalSize
    }
}

// MARK: - Equatable for ThumbnailSize

extension ThumbnailSize: Equatable {
    static func == (lhs: ThumbnailSize, rhs: ThumbnailSize) -> Bool {
        switch (lhs, rhs) {
        case (.avatar, .avatar): return true
        case (.messagePreview, .messagePreview): return true
        case (.custom(let w1, let h1), .custom(let w2, let h2)): return w1 == w2 && h1 == h2
        default: return false
        }
    }
}

// MARK: - String SHA256 Extension

private extension String {
    var sha256Hash: String {
        let hash = SHA256.hash(data: Data(self.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

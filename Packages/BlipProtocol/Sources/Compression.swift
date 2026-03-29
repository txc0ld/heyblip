import Foundation
import Compression

/// Errors from compression/decompression operations.
public enum CompressionError: Error, Sendable, Equatable {
    case compressionFailed
    case decompressionFailed
    case outputTooLarge(Int)
}

/// Zlib compression using Apple's built-in Compression framework.
///
/// Policy from spec Section 6.7:
/// - < 100 bytes: no compression
/// - 100-256 bytes: compress if result is smaller
/// - > 256 bytes: always compress (zlib level 6)
/// - Pre-compressed data (Opus, JPEG): caller should skip
public enum PayloadCompressor {

    /// Minimum payload size to attempt compression.
    public static let minCompressionSize = 100

    /// Threshold above which compression is always applied.
    public static let alwaysCompressSize = 256

    /// Maximum decompressed output size (256 KB safety limit).
    public static let maxDecompressedSize = 262_144

    // MARK: - Policy-aware compression

    /// Compress payload according to the spec compression policy.
    ///
    /// - Parameters:
    ///   - data: Raw payload bytes.
    ///   - isPreCompressed: If `true`, skip compression (e.g., Opus audio, JPEG images).
    /// - Returns: A `CompressionResult` indicating whether compression was applied and the output data.
    public static func compressIfNeeded(_ data: Data, isPreCompressed: Bool = false) -> CompressionResult {
        // Pre-compressed data: skip
        if isPreCompressed {
            return CompressionResult(data: data, wasCompressed: false)
        }

        // < 100 bytes: no compression
        if data.count < minCompressionSize {
            return CompressionResult(data: data, wasCompressed: false)
        }

        // Attempt compression
        guard let compressed = compress(data) else {
            return CompressionResult(data: data, wasCompressed: false)
        }

        // 100-256 bytes: compress only if result is smaller
        if data.count <= alwaysCompressSize {
            if compressed.count < data.count {
                return CompressionResult(data: compressed, wasCompressed: true)
            } else {
                return CompressionResult(data: data, wasCompressed: false)
            }
        }

        // > 256 bytes: always use compressed output (even if larger, per spec)
        return CompressionResult(data: compressed, wasCompressed: true)
    }

    // MARK: - Raw compression / decompression

    /// Compress data using zlib.
    ///
    /// Returns `nil` on failure.
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // Allocate output buffer (worst case: input size + some overhead).
        let destinationCapacity = max(data.count + 64, data.count * 2)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourceBytes -> Int in
            guard let sourceBaseAddress = sourceBytes.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                destinationCapacity,
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    /// Decompress zlib-compressed data.
    ///
    /// - Throws: `CompressionError.decompressionFailed` on failure,
    ///   `CompressionError.outputTooLarge` if decompressed size exceeds safety limit.
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw CompressionError.decompressionFailed
        }

        let destinationCapacity = maxDecompressedSize
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourceBytes -> Int in
            guard let sourceBaseAddress = sourceBytes.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                destinationCapacity,
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw CompressionError.decompressionFailed
        }

        if decompressedSize >= destinationCapacity {
            throw CompressionError.outputTooLarge(decompressedSize)
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}

/// Result of a policy-aware compression attempt.
public struct CompressionResult: Sendable, Equatable {
    /// The output data (compressed or original).
    public let data: Data
    /// Whether compression was actually applied.
    public let wasCompressed: Bool
}

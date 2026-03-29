import Foundation
import CryptoKit

/// A single-tier Bloom filter using double-hashing.
///
/// Double-hashing produces `k` hash indices from two independent base hashes:
/// `h_i(x) = (h1(x) + i * h2(x)) mod m` for i in 0..<k
///
/// This achieves the same false-positive rate as `k` independent hash functions
/// with much lower computational cost.
public struct BloomFilterTier: Sendable {

    /// Number of bits in the filter.
    public let bitCount: Int

    /// Number of hash functions (derived from optimal formula).
    public let hashCount: Int

    /// The bit array stored as bytes.
    private var storage: [UInt8]

    /// Number of elements inserted.
    public private(set) var insertedCount: Int

    /// Create a Bloom filter tier with the given size in bytes and optimal hash count
    /// for the expected number of elements.
    ///
    /// - Parameters:
    ///   - sizeInBytes: Size of the bit array in bytes.
    ///   - expectedElements: Expected number of elements (used to compute optimal k).
    public init(sizeInBytes: Int, expectedElements: Int) {
        self.bitCount = sizeInBytes * 8
        self.storage = [UInt8](repeating: 0, count: sizeInBytes)
        self.insertedCount = 0

        // Optimal k = (m/n) * ln(2), minimum 1
        if expectedElements > 0 {
            let optimal = Int(round(Double(bitCount) / Double(expectedElements) * 0.693147))
            self.hashCount = max(1, min(optimal, 20))
        } else {
            self.hashCount = 7
        }
    }

    // MARK: - Insert / Query

    /// Insert an element into the filter.
    public mutating func insert(_ element: Data) {
        let (h1, h2) = baseHashes(element)
        for i in 0 ..< hashCount {
            let idx = bitIndex(h1: h1, h2: h2, i: i)
            setBit(at: idx)
        }
        insertedCount += 1
    }

    /// Check if an element might be in the filter.
    ///
    /// Returns `true` if the element might be present (with some false-positive probability),
    /// or `false` if the element is definitely not present.
    public func mightContain(_ element: Data) -> Bool {
        let (h1, h2) = baseHashes(element)
        for i in 0 ..< hashCount {
            let idx = bitIndex(h1: h1, h2: h2, i: i)
            if !getBit(at: idx) {
                return false
            }
        }
        return true
    }

    /// Reset the filter, clearing all bits.
    public mutating func reset() {
        storage = [UInt8](repeating: 0, count: storage.count)
        insertedCount = 0
    }

    /// Estimated false-positive probability at current fill level.
    public var estimatedFalsePositiveRate: Double {
        guard bitCount > 0 else { return 1.0 }
        let fillRatio = 1.0 - exp(-Double(hashCount * insertedCount) / Double(bitCount))
        return pow(fillRatio, Double(hashCount))
    }

    // MARK: - Double hashing internals

    /// Compute two independent base hashes from the element.
    ///
    /// Uses SHA-256: first 8 bytes for h1, next 8 bytes for h2.
    private func baseHashes(_ element: Data) -> (UInt64, UInt64) {
        let hash = SHA256.hash(data: element)
        let bytes = Array(hash)

        // Read UInt64 values byte-by-byte to avoid alignment issues.
        var h1: UInt64 = 0
        for i in 0..<8 {
            h1 = (h1 << 8) | UInt64(bytes[i])
        }
        var h2: UInt64 = 0
        for i in 8..<16 {
            h2 = (h2 << 8) | UInt64(bytes[i])
        }

        return (h1, h2)
    }

    /// Compute the bit index for the i-th hash function using double hashing.
    private func bitIndex(h1: UInt64, h2: UInt64, i: Int) -> Int {
        let combined = h1 &+ UInt64(i) &* h2
        return Int(combined % UInt64(bitCount))
    }

    private func getBit(at index: Int) -> Bool {
        let byteIndex = index / 8
        let bitOffset = index % 8
        return (storage[byteIndex] & (1 << bitOffset)) != 0
    }

    private mutating func setBit(at index: Int) {
        let byteIndex = index / 8
        let bitOffset = index % 8
        storage[byteIndex] |= (1 << bitOffset)
    }
}

/// Multi-tier Bloom filter for packet deduplication (spec Section 8.7).
///
/// Three tiers with different windows and sizes:
/// - Hot:  4 KB,  60-second window (fastest check)
/// - Warm: 16 KB, 10-minute window (recent history)
/// - Cold: 64 KB, 2-hour window   (extended dedup)
///
/// Check order: Hot -> Warm -> Cold.
/// Uses double-hashing for ~0.01% effective false-positive rate per tier.
public final class MultiTierBloomFilter: @unchecked Sendable {

    // MARK: - Tier configuration

    /// Hot tier: 4 KB, 60 seconds.
    public static let hotSizeBytes   = 4_096
    public static let hotWindowSec   = 60.0
    public static let hotExpectedElements = 500

    /// Warm tier: 16 KB, 10 minutes.
    public static let warmSizeBytes  = 16_384
    public static let warmWindowSec  = 600.0
    public static let warmExpectedElements = 5_000

    /// Cold tier: 64 KB, 2 hours.
    public static let coldSizeBytes  = 65_536
    public static let coldWindowSec  = 7_200.0
    public static let coldExpectedElements = 50_000

    // MARK: - State

    private let lock = NSLock()
    private var hotTier:  BloomFilterTier
    private var warmTier: BloomFilterTier
    private var coldTier: BloomFilterTier

    private var hotCreatedAt:  Date
    private var warmCreatedAt: Date
    private var coldCreatedAt: Date

    public init() {
        let now = Date()

        hotTier = BloomFilterTier(
            sizeInBytes: Self.hotSizeBytes,
            expectedElements: Self.hotExpectedElements
        )
        warmTier = BloomFilterTier(
            sizeInBytes: Self.warmSizeBytes,
            expectedElements: Self.warmExpectedElements
        )
        coldTier = BloomFilterTier(
            sizeInBytes: Self.coldSizeBytes,
            expectedElements: Self.coldExpectedElements
        )

        hotCreatedAt = now
        warmCreatedAt = now
        coldCreatedAt = now
    }

    // MARK: - Public API

    /// Insert a packet ID into the hot tier. Also promotes to warm/cold on roll.
    public func insert(_ packetID: Data) {
        lock.lock()
        defer { lock.unlock() }

        rollTiersIfNeeded()
        hotTier.insert(packetID)
    }

    /// Check if a packet ID has been seen. Checks hot -> warm -> cold.
    ///
    /// Returns `true` if the ID was probably seen (with very low false-positive rate).
    public func contains(_ packetID: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        rollTiersIfNeeded()

        if hotTier.mightContain(packetID) { return true }
        if warmTier.mightContain(packetID) { return true }
        if coldTier.mightContain(packetID) { return true }
        return false
    }

    /// Force tier rotation for testing or manual control.
    public func rollTiers() {
        lock.lock()
        defer { lock.unlock() }
        rollTiersIfNeeded()
    }

    /// Reset all tiers.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        hotTier.reset()
        warmTier.reset()
        coldTier.reset()
        hotCreatedAt = now
        warmCreatedAt = now
        coldCreatedAt = now
    }

    /// Current insertion counts per tier (for diagnostics).
    public var tierCounts: (hot: Int, warm: Int, cold: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hotTier.insertedCount, warmTier.insertedCount, coldTier.insertedCount)
    }

    // MARK: - Tier rolling

    /// Roll tiers when their windows expire.
    ///
    /// When the hot tier expires:
    ///   1. Cold tier is discarded
    ///   2. Warm tier becomes cold tier
    ///   3. Hot tier becomes warm tier
    ///   4. New empty hot tier is created
    private func rollTiersIfNeeded() {
        let now = Date()

        // Check cold expiry
        if now.timeIntervalSince(coldCreatedAt) > Self.coldWindowSec {
            coldTier.reset()
            coldCreatedAt = now
        }

        // Check warm expiry: warm -> cold
        if now.timeIntervalSince(warmCreatedAt) > Self.warmWindowSec {
            coldTier = warmTier
            coldCreatedAt = warmCreatedAt
            warmTier = BloomFilterTier(
                sizeInBytes: Self.warmSizeBytes,
                expectedElements: Self.warmExpectedElements
            )
            warmCreatedAt = now
        }

        // Check hot expiry: hot -> warm
        if now.timeIntervalSince(hotCreatedAt) > Self.hotWindowSec {
            warmTier = hotTier
            warmCreatedAt = hotCreatedAt
            hotTier = BloomFilterTier(
                sizeInBytes: Self.hotSizeBytes,
                expectedElements: Self.hotExpectedElements
            )
            hotCreatedAt = now
        }
    }
}

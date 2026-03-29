import Foundation
import CryptoKit

/// Golomb-Coded Set (GCS) filter for compact message ID synchronization (spec Section 5.8).
///
/// A GCS encodes a sorted set of hash values using Golomb-Rice coding, which is
/// extremely compact for sets with a target false-positive rate. This is used for
/// peer-to-peer reconciliation: peers exchange GCS filters of recently-seen message
/// IDs and request any they are missing.
///
/// - Max filter size: 400 bytes
/// - Target false-positive rate: 1% (P = 1/M, M = 100 = ceil(1/0.01))
/// - Golomb parameter: P (log2 of M, used as the Rice parameter)
public enum GCSFilter {

    /// Maximum encoded filter size in bytes.
    public static let maxEncodedSize = 400

    /// Target false-positive rate (1%).
    public static let targetFalsePositiveRate = 0.01

    /// Golomb-Rice parameter M = ceil(1/FPR).
    /// With 1% FPR, M = 100. We use the nearest power-of-2 for efficient Rice coding: 128.
    /// This gives a slightly better FPR than the 1% target.
    public static let golombM: UInt64 = 128

    /// Rice parameter P = log2(M) = 7.
    public static let riceParameter: Int = 7

    // MARK: - Encode

    /// Encode a set of message IDs into a compact GCS filter.
    ///
    /// - Parameters:
    ///   - messageIDs: The set of message ID data values to encode.
    ///   - maxSize: Maximum output size in bytes (default 400).
    /// - Returns: The encoded GCS data, or `nil` if the set cannot fit within `maxSize`.
    public static func encode(_ messageIDs: Set<Data>, maxSize: Int = maxEncodedSize) -> Data? {
        guard !messageIDs.isEmpty else {
            return Data()
        }

        let n = UInt64(messageIDs.count)
        let F = n * golombM  // Hash range = N * M

        // Hash each message ID into [0, F) and sort.
        var hashes: [UInt64] = messageIDs.map { id in
            hashToRange(id, range: F)
        }
        hashes.sort()

        // Remove duplicates (extremely unlikely with a good hash, but defensive).
        hashes = Array(Set(hashes)).sorted()

        // Encode: first write N as a UInt32 big-endian, then Golomb-Rice encode the
        // sorted differences (deltas).
        var writer = BitWriter()

        // Write element count
        let countBytes = withUnsafeBytes(of: UInt32(hashes.count).bigEndian) { Data($0) }
        for byte in countBytes {
            writer.writeBits(UInt64(byte), count: 8)
        }

        // Golomb-Rice encode the deltas
        var prev: UInt64 = 0
        for hash in hashes {
            let delta = hash - prev
            golombRiceEncode(delta, parameter: riceParameter, writer: &writer)
            prev = hash
        }

        let encoded = writer.finalize()

        // Check size constraint
        guard encoded.count <= maxSize else {
            return nil
        }

        return encoded
    }

    // MARK: - Decode

    /// Decode a GCS filter back into a set of hash values.
    ///
    /// Returns the sorted set of hash values that were encoded.
    /// To check membership, hash the query ID with the same hash function and check
    /// if the hash appears in the decoded set.
    public static func decode(_ data: Data) -> [UInt64]? {
        guard data.count >= 4 else {
            return data.isEmpty ? [] : nil
        }

        var reader = BitReader(data: data)

        // Read element count (UInt32 big-endian)
        guard let countBits = reader.readBits(32) else { return nil }
        let count = UInt32(countBits)

        guard count > 0 else { return [] }
        guard count < 100_000 else { return nil }  // Sanity limit

        // Golomb-Rice decode the deltas
        var hashes: [UInt64] = []
        hashes.reserveCapacity(Int(count))
        var prev: UInt64 = 0

        for _ in 0 ..< count {
            guard let delta = golombRiceDecode(parameter: riceParameter, reader: &reader) else {
                return nil
            }
            let hash = prev + delta
            hashes.append(hash)
            prev = hash
        }

        return hashes
    }

    // MARK: - Membership test

    /// Check if a message ID might be contained in an encoded GCS filter.
    ///
    /// - Parameters:
    ///   - messageID: The message ID to check.
    ///   - encodedFilter: The GCS-encoded filter data.
    ///   - elementCount: Number of elements in the filter (from the header).
    /// - Returns: `true` if the ID might be in the set (with ~1% false-positive rate).
    public static func mightContain(_ messageID: Data, in encodedFilter: Data) -> Bool {
        guard let hashes = decode(encodedFilter) else { return false }
        guard !hashes.isEmpty else { return false }

        let n = UInt64(hashes.count)
        let F = n * golombM
        let target = hashToRange(messageID, range: F)

        // Binary search in sorted hashes
        var lo = 0
        var hi = hashes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if hashes[mid] == target {
                return true
            } else if hashes[mid] < target {
                lo = mid + 1
            } else {
                if mid == 0 { break }
                hi = mid - 1
            }
        }
        return false
    }

    /// Return the set of message IDs from `localIDs` that are NOT present in the
    /// remote peer's GCS filter. These are candidates for requesting from the peer.
    public static func findMissing(localIDs: Set<Data>, remoteFilter: Data) -> Set<Data> {
        guard let remoteHashes = decode(remoteFilter) else { return localIDs }
        guard !remoteHashes.isEmpty else { return localIDs }

        let remoteSet = Set(remoteHashes)
        let n = UInt64(remoteHashes.count)
        let F = n * golombM

        var missing = Set<Data>()
        for id in localIDs {
            let h = hashToRange(id, range: F)
            if !remoteSet.contains(h) {
                missing.insert(id)
            }
        }
        return missing
    }

    // MARK: - Hash function

    /// Hash a message ID into the range [0, range) using SipHash-derived approach.
    ///
    /// We use SHA-256 truncated to 8 bytes, then mod range.
    static func hashToRange(_ data: Data, range: UInt64) -> UInt64 {
        guard range > 0 else { return 0 }
        let digest = SHA256.hash(data: data)
        let bytes = Array(digest)
        // Read UInt64 byte-by-byte to avoid alignment issues.
        var h: UInt64 = 0
        for i in 0..<8 {
            h = (h << 8) | UInt64(bytes[i])
        }
        return h % range
    }

    // MARK: - Golomb-Rice coding

    /// Encode a value using Golomb-Rice coding.
    ///
    /// For parameter P:
    /// - quotient q = value >> P  (unary encoded: q ones followed by a zero)
    /// - remainder r = value & ((1 << P) - 1)  (binary encoded in P bits)
    static func golombRiceEncode(_ value: UInt64, parameter: Int, writer: inout BitWriter) {
        let q = value >> parameter
        let r = value & ((1 << parameter) - 1)

        // Unary encode quotient: q ones + one zero
        for _ in 0 ..< q {
            writer.writeBit(1)
        }
        writer.writeBit(0)

        // Binary encode remainder in P bits
        writer.writeBits(r, count: parameter)
    }

    /// Decode a Golomb-Rice coded value.
    static func golombRiceDecode(parameter: Int, reader: inout BitReader) -> UInt64? {
        // Read unary quotient: count ones until we hit a zero
        var q: UInt64 = 0
        while true {
            guard let bit = reader.readBit() else { return nil }
            if bit == 0 { break }
            q += 1
            // Safety limit
            if q > 1_000_000 { return nil }
        }

        // Read binary remainder (P bits)
        guard let r = reader.readBits(parameter) else { return nil }

        return (q << parameter) | r
    }
}

// MARK: - Bit Writer

/// A utility for writing individual bits to a byte buffer.
struct BitWriter {
    private var buffer: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitPosition: Int = 0  // 0-7, next bit position within currentByte

    mutating func writeBit(_ bit: UInt8) {
        currentByte |= ((bit & 1) << (7 - bitPosition))
        bitPosition += 1
        if bitPosition == 8 {
            buffer.append(currentByte)
            currentByte = 0
            bitPosition = 0
        }
    }

    mutating func writeBits(_ value: UInt64, count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            writeBit(UInt8((value >> i) & 1))
        }
    }

    /// Finalize and return the buffer, padding the last byte with zeros.
    mutating func finalize() -> Data {
        if bitPosition > 0 {
            buffer.append(currentByte)
        }
        return Data(buffer)
    }
}

// MARK: - Bit Reader

/// A utility for reading individual bits from a byte buffer.
struct BitReader {
    private let bytes: [UInt8]
    private var byteIndex: Int = 0
    private var bitPosition: Int = 0  // 0-7

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func readBit() -> UInt8? {
        guard byteIndex < bytes.count else { return nil }
        let bit = (bytes[byteIndex] >> (7 - bitPosition)) & 1
        bitPosition += 1
        if bitPosition == 8 {
            bitPosition = 0
            byteIndex += 1
        }
        return bit
    }

    mutating func readBits(_ count: Int) -> UInt64? {
        var value: UInt64 = 0
        for _ in 0 ..< count {
            guard let bit = readBit() else { return nil }
            value = (value << 1) | UInt64(bit)
        }
        return value
    }
}

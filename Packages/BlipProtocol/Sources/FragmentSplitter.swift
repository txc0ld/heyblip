import Foundation
import Security

/// Fragment header layout:
/// ```
/// fragmentID  (4 bytes)  -- random identifier for this fragment group
/// index       (2 bytes)  -- UInt16 big-endian, 0-based fragment index
/// total       (2 bytes)  -- UInt16 big-endian, total fragment count
/// ```
public enum FragmentHeader {
    /// Size of the fragment header in bytes.
    public static let size = 8
}

/// A single fragment produced by `FragmentSplitter`.
public struct Fragment: Sendable, Equatable {
    /// 4-byte identifier shared by all fragments of the same message.
    public let fragmentID: Data
    /// 0-based index of this fragment within the group.
    public let index: UInt16
    /// Total number of fragments in the group.
    public let total: UInt16
    /// Payload data for this fragment.
    public let data: Data

    /// Serialize the fragment header + data for transmission.
    public func serialize() -> Data {
        var result = Data()
        result.reserveCapacity(FragmentHeader.size + data.count)
        result.append(fragmentID)
        PacketSerializer.appendUInt16(&result, index)
        PacketSerializer.appendUInt16(&result, total)
        result.append(data)
        return result
    }

    /// Parse a fragment from raw wire data (fragment header + payload).
    public static func parse(_ rawData: Data) -> Fragment? {
        guard rawData.count >= FragmentHeader.size else { return nil }
        var offset = 0

        let fragmentID = Data(rawData[0 ..< 4])
        offset = 4
        let index = PacketSerializer.readUInt16(rawData, at: &offset)
        let total = PacketSerializer.readUInt16(rawData, at: &offset)
        let data = Data(rawData[offset...])

        return Fragment(
            fragmentID: fragmentID,
            index: index,
            total: total,
            data: data
        )
    }
}

/// Splits payloads that exceed the fragmentation threshold into multiple fragments.
///
/// Per spec Section 5.7:
/// - Fragmentation threshold: 416 bytes (worst case: addressed + signed)
/// - Fragment header: fragmentID (4B) + index (2B) + total (2B) = 8 bytes
/// - Fragment TTL: capped at 5 hops
public enum FragmentSplitter {

    /// Default fragmentation threshold (worst case: addressed + signed).
    public static let threshold = Packet.fragmentationThreshold

    /// Fragment header overhead in bytes.
    public static let headerOverhead = FragmentHeader.size

    /// Maximum TTL for fragment packets.
    public static let maxFragmentTTL: UInt8 = 5

    /// Maximum payload data per fragment (threshold - fragment header).
    public static var maxFragmentPayload: Int {
        threshold - headerOverhead
    }

    /// Split a payload into fragments if it exceeds the threshold.
    ///
    /// - Parameters:
    ///   - payload: The data to fragment.
    ///   - threshold: Override the default threshold (useful for testing).
    /// - Returns: An array of `Fragment` values. If the payload fits in one fragment,
    ///   a single-element array is returned.
    public static func split(_ payload: Data, threshold: Int = FragmentSplitter.threshold) -> [Fragment] {
        let maxChunkSize = threshold - headerOverhead
        guard maxChunkSize > 0 else { return [] }

        // If it fits, still wrap it in a single fragment for consistency at the wire level.
        // But callers should check `needsFragmentation` first and skip this for efficiency.
        let fragmentID = generateFragmentID()

        if payload.count <= maxChunkSize {
            return [Fragment(
                fragmentID: fragmentID,
                index: 0,
                total: 1,
                data: payload
            )]
        }

        var fragments: [Fragment] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxChunkSize, payload.count)
            let chunk = Data(payload[offset ..< end])
            fragments.append(Fragment(
                fragmentID: fragmentID,
                index: UInt16(fragments.count),
                total: 0, // Placeholder, set below
                data: chunk
            ))
            offset = end
        }

        // Set the correct total on each fragment
        let total = UInt16(fragments.count)
        fragments = fragments.map { frag in
            Fragment(
                fragmentID: frag.fragmentID,
                index: frag.index,
                total: total,
                data: frag.data
            )
        }

        return fragments
    }

    /// Whether a payload requires fragmentation.
    public static func needsFragmentation(_ payload: Data, threshold: Int = FragmentSplitter.threshold) -> Bool {
        payload.count > (threshold - headerOverhead)
    }

    /// Calculate the number of fragments needed for a given payload size.
    public static func fragmentCount(for payloadSize: Int, threshold: Int = FragmentSplitter.threshold) -> Int {
        let maxChunkSize = threshold - headerOverhead
        guard maxChunkSize > 0 else { return 0 }
        return (payloadSize + maxChunkSize - 1) / maxChunkSize
    }

    // MARK: - Fragment ID generation

    /// Generate a 4-byte random fragment ID.
    private static func generateFragmentID() -> Data {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback to system random if SecRandom fails (extremely unlikely)
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }
}

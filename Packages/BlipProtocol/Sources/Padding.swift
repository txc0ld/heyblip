import Foundation

/// Padding to block boundaries for traffic analysis resistance (spec Section 6.6).
///
/// Block sizes: 256, 512, 1024, 2048 bytes for data within those tiers.
/// Data exceeding 2048 bytes is padded to the next multiple of 256.
///
/// The padding scheme uses a modified PKCS#7 approach:
/// 1. Data is padded to the nearest block boundary.
/// 2. If the data is already at a boundary, it is padded to the next tier.
/// 3. The last byte stores the padding count modulo 256 (0 means 256).
/// 4. All padding bytes have the same value as the last byte.
public enum PacketPadding {

    /// Supported block sizes in ascending order.
    public static let blockSizes: [Int] = [256, 512, 1024, 2048]

    /// Maximum padded size.
    public static let maxBlockSize = 2048

    /// Granularity for sizes beyond the tier system.
    private static let overflowGranularity = 256

    // MARK: - Pad

    /// Pad data to the nearest block boundary.
    ///
    /// The padding always has at least 1 byte so the scheme is unambiguous.
    public static func pad(_ data: Data) -> Data {
        let targetSize = paddedSize(for: data.count)
        let paddingLength = targetSize - data.count

        // Padding byte: paddingLength mod 256. For 256 this wraps to 0.
        let paddingByte = UInt8(truncatingIfNeeded: paddingLength)

        var padded = data
        padded.append(Data(repeating: paddingByte, count: paddingLength))
        return padded
    }

    // MARK: - Unpad

    /// Remove padding and recover the original data.
    ///
    /// Returns `nil` if the padding is invalid.
    public static func unpad(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let lastByte = data[data.count - 1]

        // Determine padding length: 0 means 256, otherwise it's the byte value.
        let paddingLength: Int
        if lastByte == 0 {
            paddingLength = 256
        } else {
            paddingLength = Int(lastByte)
        }

        guard paddingLength >= 1, paddingLength <= data.count else {
            return nil
        }

        // Verify all padding bytes match
        let paddingStart = data.count - paddingLength
        for i in paddingStart ..< data.count {
            if data[i] != lastByte {
                return nil
            }
        }

        return Data(data[0 ..< paddingStart])
    }

    // MARK: - Block size helpers

    /// Compute the padded size for a given data length.
    ///
    /// Within the tier system (0-2048), returns the smallest tier boundary that
    /// leaves padding in [1, 256].
    /// Beyond 2048, rounds up to the next multiple of 256.
    /// Padding is always in [1, 256].
    public static func paddedSize(for dataLength: Int) -> Int {
        // Check tier boundaries
        for size in blockSizes {
            let padding = size - dataLength
            if padding >= 1 && padding <= 256 {
                return size
            }
        }

        // Beyond the tiers: round up to next multiple of 256
        let granularity = overflowGranularity
        let multiple = ((dataLength / granularity) + 1) * granularity
        return multiple
    }

    /// Find the next block size boundary for the given data length.
    ///
    /// Returns the smallest block size that is >= dataLength.
    /// If dataLength exceeds 2048, rounds up to the next multiple of 2048.
    public static func nextBlockSize(for dataLength: Int) -> Int {
        for size in blockSizes {
            if dataLength <= size {
                return size
            }
        }
        return ((dataLength + maxBlockSize - 1) / maxBlockSize) * maxBlockSize
    }
}

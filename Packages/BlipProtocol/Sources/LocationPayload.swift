import Foundation

/// Binary payload for location sharing packets (spec Section 6.4, types 0x50-0x53).
///
/// Layout (29 bytes):
///   [0-7]:   latitude  (Float64, big-endian)
///   [8-15]:  longitude (Float64, big-endian)
///   [16-19]: accuracy  (Float32, big-endian, meters)
///   [20-27]: timestamp (UInt64, big-endian, Unix epoch ms)
///   [28]:    flags     (UInt8: bit 0 = isBeacon)
public struct LocationPayload: Sendable, Equatable {

    /// Latitude in degrees (-90 to 90).
    public let latitude: Double
    /// Longitude in degrees (-180 to 180).
    public let longitude: Double
    /// Horizontal accuracy in meters.
    public let accuracy: Float
    /// Unix epoch timestamp in milliseconds.
    public let timestamp: UInt64
    /// Whether this is an "I'm Here" beacon.
    public let isBeacon: Bool

    /// Fixed serialized size in bytes.
    public static let serializedSize = 29

    /// Beacon TTL: 30 minutes.
    public static let beaconTTL: TimeInterval = 1800

    /// Maximum location update rate: 1 per 30 seconds.
    public static let updateInterval: TimeInterval = 30

    public init(
        latitude: Double,
        longitude: Double,
        accuracy: Float,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        isBeacon: Bool = false
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.isBeacon = isBeacon
    }

    // MARK: - Serialization

    /// Serialize to binary data.
    public func serialize() -> Data {
        var data = Data(capacity: Self.serializedSize)
        var lat = latitude.bitPattern.bigEndian
        var lon = longitude.bitPattern.bigEndian
        var acc = accuracy.bitPattern.bigEndian
        var ts = timestamp.bigEndian
        let flags: UInt8 = isBeacon ? 0x01 : 0x00

        withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &acc) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        data.append(flags)

        return data
    }

    /// Deserialize from binary data.
    public static func deserialize(from data: Data) -> LocationPayload? {
        guard data.count >= serializedSize else { return nil }

        // Read with manual byte extraction to avoid alignment issues.
        var latBits: UInt64 = 0
        var lonBits: UInt64 = 0
        var accBits: UInt32 = 0
        var ts: UInt64 = 0

        withUnsafeMutableBytes(of: &latBits) { buf in
            data.copyBytes(to: buf.bindMemory(to: UInt8.self), from: 0..<8)
        }
        withUnsafeMutableBytes(of: &lonBits) { buf in
            data.copyBytes(to: buf.bindMemory(to: UInt8.self), from: 8..<16)
        }
        withUnsafeMutableBytes(of: &accBits) { buf in
            data.copyBytes(to: buf.bindMemory(to: UInt8.self), from: 16..<20)
        }
        withUnsafeMutableBytes(of: &ts) { buf in
            data.copyBytes(to: buf.bindMemory(to: UInt8.self), from: 20..<28)
        }
        let flags = data[28]

        return LocationPayload(
            latitude: Double(bitPattern: UInt64(bigEndian: latBits)),
            longitude: Double(bitPattern: UInt64(bigEndian: lonBits)),
            accuracy: Float(bitPattern: UInt32(bigEndian: accBits)),
            timestamp: UInt64(bigEndian: ts),
            isBeacon: (flags & 0x01) != 0
        )
    }

    // MARK: - Helpers

    /// Age of this location update in seconds.
    public var age: TimeInterval {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard nowMs > timestamp else { return 0 }
        return Double(nowMs - timestamp) / 1000.0
    }

    /// Whether this beacon has expired (older than 30 minutes).
    public var isExpired: Bool {
        age > Self.beaconTTL
    }
}

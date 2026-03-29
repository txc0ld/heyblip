import Testing
import Foundation
@testable import FestiChatProtocol

@Suite("Location Payload Serialization")
struct LocationPayloadSerializationTests {

    @Test("Round-trip serialization preserves all fields")
    func roundTrip() {
        let original = LocationPayload(
            latitude: 51.0043,
            longitude: -2.5856,
            accuracy: 8.5,
            timestamp: 1711612800000,
            isBeacon: false
        )

        let data = original.serialize()
        let decoded = LocationPayload.deserialize(from: data)

        #expect(decoded != nil)
        #expect(decoded! == original)
    }

    @Test("Serialized size is exactly 29 bytes")
    func serializedSize() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 0, timestamp: 0
        )
        #expect(payload.serialize().count == LocationPayload.serializedSize)
    }

    @Test("Beacon flag serializes correctly")
    func beaconFlag() {
        let beacon = LocationPayload(
            latitude: 51.0, longitude: -2.5, accuracy: 5.0,
            timestamp: 1711612800000, isBeacon: true
        )

        let data = beacon.serialize()
        let decoded = LocationPayload.deserialize(from: data)

        #expect(decoded != nil)
        #expect(decoded!.isBeacon == true)
    }

    @Test("Non-beacon flag serializes correctly")
    func nonBeaconFlag() {
        let update = LocationPayload(
            latitude: 51.0, longitude: -2.5, accuracy: 5.0,
            timestamp: 1711612800000, isBeacon: false
        )

        let decoded = LocationPayload.deserialize(from: update.serialize())

        #expect(decoded != nil)
        #expect(decoded!.isBeacon == false)
    }

    @Test("Deserialization rejects undersized data")
    func rejectUndersized() {
        let tooSmall = Data(repeating: 0, count: 20)
        #expect(LocationPayload.deserialize(from: tooSmall) == nil)
    }

    @Test("Latitude and longitude extremes round-trip")
    func extremeCoordinates() {
        let extremes: [(Double, Double)] = [
            (90.0, 180.0), (-90.0, -180.0), (0.0, 0.0),
            (51.4545, -2.58789), (-33.8688, 151.2093),
        ]

        for (lat, lon) in extremes {
            let payload = LocationPayload(
                latitude: lat, longitude: lon, accuracy: 1.0, timestamp: 0
            )
            let decoded = LocationPayload.deserialize(from: payload.serialize())!
            #expect(decoded.latitude == lat)
            #expect(decoded.longitude == lon)
        }
    }

    @Test("Accuracy preserves Float precision")
    func accuracyPrecision() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 12.75, timestamp: 0
        )
        let decoded = LocationPayload.deserialize(from: payload.serialize())!
        #expect(decoded.accuracy == 12.75)
    }

    @Test("Timestamp preserves millisecond precision")
    func timestampPrecision() {
        let ts: UInt64 = 1711612800123
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 0, timestamp: ts
        )
        let decoded = LocationPayload.deserialize(from: payload.serialize())!
        #expect(decoded.timestamp == ts)
    }
}

@Suite("Location Payload Expiry")
struct LocationPayloadExpiryTests {

    @Test("Beacon TTL is 30 minutes")
    func beaconTTL() {
        #expect(LocationPayload.beaconTTL == 1800)
    }

    @Test("Update interval is 30 seconds")
    func updateInterval() {
        #expect(LocationPayload.updateInterval == 30)
    }

    @Test("Fresh payload is not expired")
    func freshNotExpired() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 0,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            isBeacon: true
        )
        #expect(!payload.isExpired)
    }

    @Test("Payload older than 30 min is expired")
    func oldIsExpired() {
        let thirtyOneMinAgo = Date().addingTimeInterval(-1860)
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 0,
            timestamp: UInt64(thirtyOneMinAgo.timeIntervalSince1970 * 1000),
            isBeacon: true
        )
        #expect(payload.isExpired)
    }

    @Test("Age calculation is accurate")
    func ageCalculation() {
        let fiveMinAgo = Date().addingTimeInterval(-300)
        let payload = LocationPayload(
            latitude: 0, longitude: 0, accuracy: 0,
            timestamp: UInt64(fiveMinAgo.timeIntervalSince1970 * 1000)
        )
        // Age should be approximately 300 seconds (allow 2s tolerance)
        #expect(payload.age > 298 && payload.age < 302)
    }
}

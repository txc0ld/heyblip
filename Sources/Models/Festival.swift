import Foundation
import SwiftData

@Model
final class Festival {
    @Attribute(.unique)
    var id: UUID

    var name: String
    var coordinatesLatitude: Double
    var coordinatesLongitude: Double
    var radiusMeters: Double
    var startDate: Date
    var endDate: Date
    var stageMapImage: Data?
    var organizerSigningKey: Data
    var manifestVersion: Int

    // MARK: - Inverse Relationships

    @Relationship(deleteRule: .cascade, inverse: \Stage.festival)
    var stages: [Stage] = []

    @Relationship(deleteRule: .cascade, inverse: \Channel.festival)
    var channels: [Channel] = []

    @Relationship(inverse: \MedicalResponder.festival)
    var medicalResponders: [MedicalResponder] = []

    // MARK: - Computed Properties

    var coordinates: GeoPoint {
        get { GeoPoint(latitude: coordinatesLatitude, longitude: coordinatesLongitude) }
        set {
            coordinatesLatitude = newValue.latitude
            coordinatesLongitude = newValue.longitude
        }
    }

    var isActive: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }

    var isUpcoming: Bool {
        Date() < startDate
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        coordinates: GeoPoint,
        radiusMeters: Double,
        startDate: Date,
        endDate: Date,
        stageMapImage: Data? = nil,
        organizerSigningKey: Data,
        manifestVersion: Int = 1
    ) {
        self.id = id
        self.name = name
        self.coordinatesLatitude = coordinates.latitude
        self.coordinatesLongitude = coordinates.longitude
        self.radiusMeters = radiusMeters
        self.startDate = startDate
        self.endDate = endDate
        self.stageMapImage = stageMapImage
        self.organizerSigningKey = organizerSigningKey
        self.manifestVersion = manifestVersion
    }
}

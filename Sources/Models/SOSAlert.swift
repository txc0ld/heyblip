import Foundation
import SwiftData

// MARK: - Enums

enum SOSSeverity: String, Codable, CaseIterable {
    case green
    case amber
    case red
}

enum SOSStatus: String, Codable, CaseIterable {
    case active
    case accepted
    case enRoute
    case resolved
}

enum SOSResolution: String, Codable, CaseIterable {
    case treatedOnSite
    case transported
    case falseAlarm
    case cancelled
}

// MARK: - Model

@Model
final class SOSAlert {
    @Attribute(.unique)
    var id: UUID

    var reporter: User?
    var reportedFor: Friend?
    var severityRaw: String
    var preciseLocationLatitude: Double
    var preciseLocationLongitude: Double
    var fuzzyLocation: String
    var message: String?
    var alertDescription: String?
    var statusRaw: String

    @Relationship
    var acceptedBy: MedicalResponder?

    var acceptedAt: Date?
    var resolvedAt: Date?
    var resolutionRaw: String?
    var falseAlarmCount: Int
    var createdAt: Date
    var expiresAt: Date

    // MARK: - Computed Properties

    var severity: SOSSeverity {
        get { SOSSeverity(rawValue: severityRaw) ?? .green }
        set { severityRaw = newValue.rawValue }
    }

    var status: SOSStatus {
        get { SOSStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var resolution: SOSResolution? {
        get {
            guard let raw = resolutionRaw else { return nil }
            return SOSResolution(rawValue: raw)
        }
        set { resolutionRaw = newValue?.rawValue }
    }

    var preciseLocation: GeoPoint {
        get {
            GeoPoint(latitude: preciseLocationLatitude, longitude: preciseLocationLongitude)
        }
        set {
            preciseLocationLatitude = newValue.latitude
            preciseLocationLongitude = newValue.longitude
        }
    }

    var isActive: Bool {
        status == .active || status == .accepted || status == .enRoute
    }

    var isResolved: Bool {
        status == .resolved
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        reporter: User? = nil,
        reportedFor: Friend? = nil,
        severity: SOSSeverity = .green,
        preciseLocation: GeoPoint,
        fuzzyLocation: String,
        message: String? = nil,
        alertDescription: String? = nil,
        status: SOSStatus = .active,
        acceptedBy: MedicalResponder? = nil,
        acceptedAt: Date? = nil,
        resolvedAt: Date? = nil,
        resolution: SOSResolution? = nil,
        falseAlarmCount: Int = 0,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.reporter = reporter
        self.reportedFor = reportedFor
        self.severityRaw = severity.rawValue
        self.preciseLocationLatitude = preciseLocation.latitude
        self.preciseLocationLongitude = preciseLocation.longitude
        self.fuzzyLocation = fuzzyLocation
        self.message = message
        self.alertDescription = alertDescription
        self.statusRaw = status.rawValue
        self.acceptedBy = acceptedBy
        self.acceptedAt = acceptedAt
        self.resolvedAt = resolvedAt
        self.resolutionRaw = resolution?.rawValue
        self.falseAlarmCount = falseAlarmCount
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

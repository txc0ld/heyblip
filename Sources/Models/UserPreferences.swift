import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums

enum AppTheme: String, Codable, CaseIterable {
    case system
    case light
    case dark

    /// Returns the explicit color scheme, or `nil` to follow device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Display label for the picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SF Symbol icon for each mode.
    var icon: String {
        switch self {
        case .system: return "gearshape.fill"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

enum PTTMode: String, Codable, CaseIterable {
    case holdToTalk
    case toggleTalk
}

enum TransportMode: String, Codable, CaseIterable {
    case bleOnly
    case bleAndWifi
    case allRadios

    var label: String {
        switch self {
        case .bleOnly: return "BLE Only"
        case .bleAndWifi: return "BLE + WiFi"
        case .allRadios: return "All Radios"
        }
    }

    var icon: String {
        switch self {
        case .bleOnly: return "antenna.radiowaves.left.and.right.slash"
        case .bleAndWifi: return "wifi"
        case .allRadios: return "antenna.radiowaves.left.and.right"
        }
    }

    var caption: String {
        switch self {
        case .bleOnly: return "Mesh only, zero internet. Best for events."
        case .bleAndWifi: return "Mesh + WiFi relay for better range."
        case .allRadios: return "BLE + WiFi + Cellular. Maximum connectivity."
        }
    }
}

enum MapStyle: String, Codable, CaseIterable {
    case satellite
    case standard
    case hybrid
}

// MARK: - Model

@Model
final class UserPreferences {
    @Attribute(.unique)
    var id: UUID

    var themeRaw: String
    var defaultLocationSharingRaw: String
    var proximityAlertsEnabled: Bool
    var breadcrumbsEnabled: Bool
    var notificationsEnabled: Bool
    var pttModeRaw: String
    var autoJoinNearbyChannels: Bool
    var crowdPulseVisible: Bool
    var nearbyVisibilityEnabled: Bool
    var friendFinderMapStyleRaw: String
    var lastEventID: UUID?

    // MARK: - Push Notification Preferences (HEY-1321)
    //
    // Per-type toggles that layer on top of the global `notificationsEnabled`
    // flag. SOS intentionally has no toggle — it is always delivered.
    //
    // `quietHours*` are stored as minute-of-day in UTC (0..<1440) so the
    // server evaluates them in a single timezone. The device sends its current
    // `utcOffsetSeconds` alongside the prefs so the server can map the user's
    // local window back to UTC without needing `TimeZone` parsing server-side.
    //
    // Defaults are filled in at init time — no Optional<Bool> — so SwiftData
    // lightweight migration populates existing rows automatically.

    var notificationsDMsEnabled: Bool = true
    var notificationsFriendRequestsEnabled: Bool = true
    var notificationsGroupMentionsEnabled: Bool = true
    var notificationsVoiceNotesEnabled: Bool = true
    var quietHoursStartUtc: Int? = nil
    var quietHoursEndUtc: Int? = nil
    var utcOffsetSeconds: Int = 0

    // MARK: - Computed Properties

    var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var defaultLocationSharing: LocationPrecision {
        get { LocationPrecision(rawValue: defaultLocationSharingRaw) ?? .off }
        set { defaultLocationSharingRaw = newValue.rawValue }
    }

    var pttMode: PTTMode {
        get { PTTMode(rawValue: pttModeRaw) ?? .holdToTalk }
        set { pttModeRaw = newValue.rawValue }
    }

    var friendFinderMapStyle: MapStyle {
        get { MapStyle(rawValue: friendFinderMapStyleRaw) ?? .standard }
        set { friendFinderMapStyleRaw = newValue.rawValue }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        theme: AppTheme = .system,
        defaultLocationSharing: LocationPrecision = .off,
        proximityAlertsEnabled: Bool = true,
        breadcrumbsEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        pttMode: PTTMode = .holdToTalk,
        autoJoinNearbyChannels: Bool = true,
        crowdPulseVisible: Bool = true,
        nearbyVisibilityEnabled: Bool = false,
        friendFinderMapStyle: MapStyle = .standard,
        lastEventID: UUID? = nil,
        notificationsDMsEnabled: Bool = true,
        notificationsFriendRequestsEnabled: Bool = true,
        notificationsGroupMentionsEnabled: Bool = true,
        notificationsVoiceNotesEnabled: Bool = true,
        quietHoursStartUtc: Int? = nil,
        quietHoursEndUtc: Int? = nil,
        utcOffsetSeconds: Int = 0
    ) {
        self.id = id
        self.themeRaw = theme.rawValue
        self.defaultLocationSharingRaw = defaultLocationSharing.rawValue
        self.proximityAlertsEnabled = proximityAlertsEnabled
        self.breadcrumbsEnabled = breadcrumbsEnabled
        self.notificationsEnabled = notificationsEnabled
        self.pttModeRaw = pttMode.rawValue
        self.autoJoinNearbyChannels = autoJoinNearbyChannels
        self.crowdPulseVisible = crowdPulseVisible
        self.nearbyVisibilityEnabled = nearbyVisibilityEnabled
        self.friendFinderMapStyleRaw = friendFinderMapStyle.rawValue
        self.lastEventID = lastEventID
        self.notificationsDMsEnabled = notificationsDMsEnabled
        self.notificationsFriendRequestsEnabled = notificationsFriendRequestsEnabled
        self.notificationsGroupMentionsEnabled = notificationsGroupMentionsEnabled
        self.notificationsVoiceNotesEnabled = notificationsVoiceNotesEnabled
        self.quietHoursStartUtc = quietHoursStartUtc
        self.quietHoursEndUtc = quietHoursEndUtc
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

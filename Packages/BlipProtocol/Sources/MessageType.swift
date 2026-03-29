import Foundation

/// All Blip binary protocol message types (spec Section 6.4).
///
/// Raw values are the single-byte type identifiers carried in the packet header.
public enum MessageType: UInt8, Sendable, Codable, CaseIterable {

    // MARK: - Core messaging

    /// Peer introduction (TLV: username, keys, capabilities, neighbors).
    case announce           = 0x01
    /// Public location channel message.
    case meshBroadcast      = 0x02
    /// Peer departing mesh.
    case leave              = 0x03

    // MARK: - Encryption

    /// Noise XX init / response.
    case noiseHandshake     = 0x10
    /// All private payloads (see EncryptedSubType).
    case noiseEncrypted     = 0x11

    // MARK: - Data transfer

    /// Large message fragment.
    case fragment           = 0x20
    /// GCS filter for reconciliation.
    case syncRequest        = 0x21
    /// Binary file payload.
    case fileTransfer       = 0x22
    /// Real-time push-to-talk audio chunk.
    case pttAudio           = 0x23

    // MARK: - Festival

    /// Festival organizer broadcast.
    case orgAnnouncement    = 0x30
    /// Location channel metadata.
    case channelUpdate      = 0x31

    // MARK: - Medical / SOS

    /// Priority: severity + fuzzy location.
    case sosAlert           = 0x40
    /// Responder claimed alert.
    case sosAccept          = 0x41
    /// GPS coords (encrypted to medical only).
    case sosPreciseLocation = 0x42
    /// Alert closed.
    case sosResolve         = 0x43
    /// Proximity nudge to nearby peers.
    case sosNearbyAssist    = 0x44

    // MARK: - Location sharing

    /// Encrypted GPS / geohash to specific friend.
    case locationShare      = 0x50
    /// "Where are you?" nudge.
    case locationRequest    = 0x51
    /// "I'm nearby" trigger.
    case proximityPing      = 0x52
    /// Dropped pin with label.
    case iAmHereBeacon      = 0x53
}

// MARK: - Convenience

extension MessageType: CustomStringConvertible {

    public var description: String {
        switch self {
        case .announce:           return "announce"
        case .meshBroadcast:      return "meshBroadcast"
        case .leave:              return "leave"
        case .noiseHandshake:     return "noiseHandshake"
        case .noiseEncrypted:     return "noiseEncrypted"
        case .fragment:           return "fragment"
        case .syncRequest:        return "syncRequest"
        case .fileTransfer:       return "fileTransfer"
        case .pttAudio:           return "pttAudio"
        case .orgAnnouncement:    return "orgAnnouncement"
        case .channelUpdate:      return "channelUpdate"
        case .sosAlert:           return "sosAlert"
        case .sosAccept:          return "sosAccept"
        case .sosPreciseLocation: return "sosPreciseLocation"
        case .sosResolve:         return "sosResolve"
        case .sosNearbyAssist:    return "sosNearbyAssist"
        case .locationShare:      return "locationShare"
        case .locationRequest:    return "locationRequest"
        case .proximityPing:      return "proximityPing"
        case .iAmHereBeacon:      return "iAmHereBeacon"
        }
    }

    /// Whether this message type is SOS-related and receives priority treatment.
    public var isSOS: Bool {
        switch self {
        case .sosAlert, .sosAccept, .sosPreciseLocation, .sosResolve, .sosNearbyAssist:
            return true
        default:
            return false
        }
    }

    /// Whether this type carries encrypted content that must be unwrapped via Noise.
    public var isEncrypted: Bool {
        self == .noiseEncrypted
    }
}

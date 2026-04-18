import Foundation

/// Sub-type identifiers for the first byte of a decrypted `noiseEncrypted` payload
/// (spec Section 6.5).
///
/// After decrypting a packet with type `.noiseEncrypted`, the first byte of the
/// plaintext is one of these values, indicating the actual semantic content.
public enum EncryptedSubType: UInt8, Sendable, Codable, CaseIterable {

    // MARK: - Messaging

    /// DM text.
    case privateMessage         = 0x01
    /// Group chat text.
    case groupMessage           = 0x02
    /// Message delivered acknowledgement.
    case deliveryAck            = 0x03
    /// Message read receipt.
    case readReceipt            = 0x04
    /// Opus-encoded voice note.
    case voiceNote              = 0x05
    /// Compressed image.
    case imageMessage           = 0x06
    /// Friend request with username + phone hash.
    case friendRequest          = 0x07
    /// Friend accept with phone hash confirmation.
    case friendAccept           = 0x08
    /// Typing indicator.
    case typingIndicator        = 0x09
    /// Delete a sent message by ID.
    case messageDelete          = 0x0A
    /// Edited content for a sent message by ID.
    case messageEdit            = 0x0B

    // MARK: - Profile

    /// Request full-resolution profile picture.
    case profileRequest         = 0x10
    /// Full-resolution profile picture data.
    case profileResponse        = 0x11

    // MARK: - Group management

    /// Sender key wrapped in pairwise Noise session.
    case groupKeyDistribution   = 0x12
    /// Admin adds a member.
    case groupMemberAdd         = 0x13
    /// Admin removes a member.
    case groupMemberRemove      = 0x14
    /// Ownership / admin transfer.
    case groupAdminChange       = 0x15

    // MARK: - Reputation

    /// Hashed user ID for mesh-level reputation (sent to direct peers).
    case blockVote              = 0x16
    /// Opus-encoded push-to-talk audio (DM, addressed packet).
    case pttAudio               = 0x17
}

// MARK: - CustomStringConvertible

extension EncryptedSubType: CustomStringConvertible {

    public var description: String {
        switch self {
        case .privateMessage:       return "privateMessage"
        case .groupMessage:         return "groupMessage"
        case .deliveryAck:          return "deliveryAck"
        case .readReceipt:          return "readReceipt"
        case .voiceNote:            return "voiceNote"
        case .imageMessage:         return "imageMessage"
        case .friendRequest:        return "friendRequest"
        case .friendAccept:         return "friendAccept"
        case .typingIndicator:      return "typingIndicator"
        case .messageDelete:        return "messageDelete"
        case .messageEdit:          return "messageEdit"
        case .profileRequest:       return "profileRequest"
        case .profileResponse:      return "profileResponse"
        case .groupKeyDistribution: return "groupKeyDistribution"
        case .groupMemberAdd:       return "groupMemberAdd"
        case .groupMemberRemove:    return "groupMemberRemove"
        case .groupAdminChange:     return "groupAdminChange"
        case .blockVote:            return "blockVote"
        case .pttAudio:             return "pttAudio"
        }
    }

    /// Whether this sub-type carries a group management operation.
    public var isGroupManagement: Bool {
        switch self {
        case .groupKeyDistribution, .groupMemberAdd, .groupMemberRemove, .groupAdminChange:
            return true
        default:
            return false
        }
    }

    /// Whether this sub-type is a free (non-billable) action.
    public var isFreeAction: Bool {
        switch self {
        case .deliveryAck, .readReceipt, .typingIndicator, .friendRequest, .friendAccept:
            return true
        default:
            return false
        }
    }
}

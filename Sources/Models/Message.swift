import Foundation
import SwiftData

// MARK: - Enums

enum MessageType: String, Codable, CaseIterable {
    case text
    case voiceNote
    case image
    case pttAudio
}

enum MessageStatus: String, Codable, CaseIterable {
    case composing
    case queued
    case encrypting
    case failed
    case sent
    case delivered
    case read
}

// MARK: - Model

@Model
final class Message {
    @Attribute(.unique)
    var id: UUID

    var sender: User?
    var channel: Channel?
    var typeRaw: String
    /// Raw payload data for retry. For text messages this is plaintext UTF-8.
    /// For voice/image messages this is empty (retry reconstructs from attachments).
    /// Named 'rawPayload' to prevent confusion with ciphertext.
    var rawPayload: Data
    var statusRaw: String

    @Relationship(deleteRule: .nullify)
    var replyTo: Message?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment] = []

    var fragmentID: UUID?
    var fragmentIndex: Int?
    var fragmentTotal: Int?
    var isRelayed: Bool
    var hopCount: Int
    var isEdited: Bool
    var isDeleted: Bool
    var editedAt: Date?
    var createdAt: Date
    var expiresAt: Date?

    /// Reaction emoji applied to this message.
    ///
    /// Persisted locally and transmitted over the wire as
    /// `EncryptedSubType.messageReaction` whenever the local user changes their reaction.
    /// Incoming reactions from the message's other participant overwrite this value (DMs
    /// today are 1:1, so the field stores the single live reaction). `nil` means cleared.
    var reaction: String?

    // MARK: - Inverse Relationships

    @Relationship(inverse: \MessageQueue.message)
    var queueEntries: [MessageQueue] = []

    // MARK: - Computed Properties

    var type: MessageType {
        get { MessageType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    var isFragmented: Bool {
        fragmentID != nil
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sender: User? = nil,
        channel: Channel? = nil,
        type: MessageType = .text,
        rawPayload: Data = Data(),
        status: MessageStatus = .queued,
        replyTo: Message? = nil,
        fragmentID: UUID? = nil,
        fragmentIndex: Int? = nil,
        fragmentTotal: Int? = nil,
        isRelayed: Bool = false,
        hopCount: Int = 0,
        isEdited: Bool = false,
        isDeleted: Bool = false,
        editedAt: Date? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        reaction: String? = nil
    ) {
        self.id = id
        self.sender = sender
        self.channel = channel
        self.typeRaw = type.rawValue
        self.rawPayload = rawPayload
        self.statusRaw = status.rawValue
        self.replyTo = replyTo
        self.fragmentID = fragmentID
        self.fragmentIndex = fragmentIndex
        self.fragmentTotal = fragmentTotal
        self.isRelayed = isRelayed
        self.hopCount = hopCount
        self.isEdited = isEdited
        self.isDeleted = isDeleted
        self.editedAt = editedAt
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.reaction = reaction
    }
}

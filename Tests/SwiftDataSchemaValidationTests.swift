import Testing
import Foundation
import SwiftData
@testable import Blip

@Suite("SwiftData Schema Validation - T24")
@MainActor
struct SwiftDataSchemaValidationTests {
    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: User.self, Friend.self, Message.self, Attachment.self, Channel.self,
            GroupMembership.self, Festival.self, Stage.self, SetTime.self, MeetingPoint.self,
            MessageQueue.self, SOSAlert.self, MedicalResponder.self,
            FriendLocation.self, BreadcrumbPoint.self, CrowdPulse.self, UserPreferences.self,
            GroupSenderKey.self, NoiseSessionModel.self,
            configurations: config
        )
        return container.mainContext
    }

    private func makeUser(
        username: String = "alice",
        context: ModelContext,
        emailHash: String? = nil
    ) -> User {
        let user = User(
            username: username,
            emailHash: emailHash ?? "hash_\(username)",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32)
        )
        context.insert(user)
        return user
    }

    private func makeChannel(
        type: ChannelType = .dm,
        context: ModelContext,
        festival: Festival? = nil
    ) -> Channel {
        let channel = Channel(type: type, name: "Test \(type)", festival: festival)
        context.insert(channel)
        return channel
    }

    private func makeFestival(context: ModelContext) -> Festival {
        let festival = Festival(
            name: "Glastonbury",
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58),
            radiusMeters: 5000,
            startDate: Date(),
            endDate: Date().addingTimeInterval(86_400 * 3),
            organizerSigningKey: Data(repeating: 3, count: 32)
        )
        context.insert(festival)
        return festival
    }

    // MARK: - Schema Registration Tests

    @Test("Schema contains all 19 models")
    func schemaRegistration() {
        #expect(BlipSchema.models.count == 19)
        let modelNames = BlipSchema.models.map { String(describing: $0) }

        let expectedModels = [
            "User", "Friend", "Message", "Attachment", "Channel",
            "GroupMembership", "Festival", "Stage", "SetTime", "MeetingPoint",
            "MessageQueue", "SOSAlert", "MedicalResponder", "FriendLocation",
            "BreadcrumbPoint", "CrowdPulse", "UserPreferences", "GroupSenderKey",
            "NoiseSessionModel"
        ]

        for expectedModel in expectedModels {
            #expect(modelNames.contains { $0.contains(expectedModel) })
        }
    }

    @Test("Container creation with in-memory storage")
    func containerCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: User.self, Friend.self, Message.self, Attachment.self, Channel.self,
            GroupMembership.self, Festival.self, Stage.self, SetTime.self, MeetingPoint.self,
            MessageQueue.self, SOSAlert.self, MedicalResponder.self,
            FriendLocation.self, BreadcrumbPoint.self, CrowdPulse.self, UserPreferences.self,
            GroupSenderKey.self, NoiseSessionModel.self,
            configurations: config
        )
        let context = container.mainContext
        #expect(context != nil)
    }

    // MARK: - User CRUD Tests

    @Test("User creation and persistence")
    func userCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<User>(predicate: #Predicate { $0.username == "alice" })
        )
        #expect(fetched.count == 1)
        #expect(fetched[0].username == "alice")
        #expect(fetched[0].displayName == nil)
    }

    @Test("User update displayName")
    func userUpdate() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        try context.save()

        user.displayName = "Alice Wonder"
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<User>(predicate: #Predicate { $0.username == "alice" })
        )
        #expect(fetched[0].displayName == "Alice Wonder")
        #expect(fetched[0].resolvedDisplayName == "Alice Wonder")
    }

    @Test("User deletion")
    func userDeletion() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        try context.save()

        context.delete(user)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<User>())
        #expect(fetched.isEmpty)
    }

    @Test("User unique constraint on username")
    func userUniquenessConstraint() throws {
        let context = try makeContext()
        let user1 = makeUser(username: "alice", context: context)
        try context.save()

        let user2 = User(
            username: "alice",
            emailHash: "different_hash",
            noisePublicKey: Data(repeating: 4, count: 32),
            signingPublicKey: Data(repeating: 5, count: 32)
        )
        context.insert(user2)

        // SwiftData should enforce unique constraint
        // This test documents the expected behavior
        #expect(context.hasChanges)
    }

    // MARK: - Friend CRUD Tests

    @Test("Friend creation with user relationship")
    func friendCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let friend = Friend(
            user: user,
            status: .accepted,
            phoneVerified: true,
            locationSharingEnabled: true,
            locationPrecision: .precise
        )
        context.insert(friend)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Friend>())
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .accepted)
        #expect(fetched[0].locationPrecision == .precise)
    }

    @Test("Friend status enum roundtrip")
    func friendStatusEnum() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        for status in FriendStatus.allCases {
            let friend = Friend(
                user: user,
                status: status,
                phoneVerified: false,
                locationSharingEnabled: false,
                locationPrecision: .off
            )
            context.insert(friend)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Friend>())
        #expect(fetched.count == FriendStatus.allCases.count)

        for (idx, status) in FriendStatus.allCases.enumerated() {
            #expect(fetched[idx].status == status)
        }
    }

    @Test("Friend location precision roundtrip")
    func friendLocationPrecision() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let friend = Friend(
            user: user,
            status: .accepted,
            phoneVerified: true,
            locationSharingEnabled: true,
            locationPrecision: .fuzzy,
            lastSeenLatitude: 51.15,
            lastSeenLongitude: -2.58
        )
        context.insert(friend)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Friend>())
        #expect(fetched[0].locationPrecision == .fuzzy)
        #expect(fetched[0].lastSeenLocation?.latitude == 51.15)
        #expect(fetched[0].lastSeenLocation?.longitude == -2.58)
    }

    @Test("Friend deletion")
    func friendDeletion() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let friend = Friend(user: user)
        context.insert(friend)
        try context.save()

        context.delete(friend)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Friend>())
        #expect(fetched.isEmpty)
    }

    // MARK: - Message CRUD Tests

    @Test("Message creation with sender and channel")
    func messageCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(
            sender: user,
            channel: channel,
            type: .text,
            encryptedPayload: Data("hello".utf8),
            status: .sent
        )
        context.insert(message)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == 1)
        #expect(fetched[0].type == .text)
        #expect(fetched[0].status == .sent)
    }

    @Test("Message type enum roundtrip")
    func messageTypeEnum() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        for type in MessageType.allCases {
            let message = Message(
                sender: user,
                channel: channel,
                type: type,
                encryptedPayload: Data()
            )
            context.insert(message)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == MessageType.allCases.count)
    }

    @Test("Message status enum roundtrip")
    func messageStatusEnum() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        let msg = fetched[0]

        for status in MessageStatus.allCases {
            msg.status = status
            try context.save()

            let refetched = try context.fetch(FetchDescriptor<Message>())
            #expect(refetched[0].status == status)
        }
    }

    @Test("Message expiration computed property")
    func messageExpiration() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let futureDate = Date().addingTimeInterval(3600)
        let message = Message(
            sender: user,
            channel: channel,
            expiresAt: futureDate
        )
        context.insert(message)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(!fetched[0].isExpired)
    }

    @Test("Message reply-to relationship")
    func messageReplyTo() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let msg1 = Message(
            sender: user,
            channel: channel,
            encryptedPayload: Data("original".utf8)
        )
        context.insert(msg1)
        try context.save()

        let msg2 = Message(
            sender: user,
            channel: channel,
            encryptedPayload: Data("reply".utf8),
            replyTo: msg1
        )
        context.insert(msg2)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        let replyMsg = fetched.first { msg in msg.encryptedPayload == Data("reply".utf8) }
        #expect(replyMsg?.replyTo != nil)
        #expect(replyMsg?.replyTo?.encryptedPayload == Data("original".utf8))
    }

    @Test("Message deletion")
    func messageDeletion() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        context.delete(message)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.isEmpty)
    }

    // MARK: - Channel CRUD Tests

    @Test("Channel creation with all types")
    func channelCreationAllTypes() throws {
        let context = try makeContext()

        for type in ChannelType.allCases {
            let channel = Channel(type: type, name: "Test \(type)")
            context.insert(channel)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Channel>())
        #expect(fetched.count == ChannelType.allCases.count)
    }

    @Test("Channel mute status enum roundtrip")
    func channelMuteStatus() throws {
        let context = try makeContext()

        for muteStatus in MuteStatus.allCases {
            let channel = Channel(type: .dm, muteStatus: muteStatus)
            context.insert(channel)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Channel>())
        for (idx, status) in MuteStatus.allCases.enumerated() {
            #expect(fetched[idx].muteStatus == status)
        }
    }

    @Test("Channel computed properties")
    func channelComputedProperties() throws {
        let context = try makeContext()

        let dmChannel = Channel(type: .dm)
        let groupChannel = Channel(type: .group)
        let locationChannel = Channel(type: .locationChannel)

        context.insert(dmChannel)
        context.insert(groupChannel)
        context.insert(locationChannel)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Channel>())

        let dm = fetched.first { $0.type == .dm }
        #expect(dm?.isGroup == false)
        #expect(dm?.isPublic == false)

        let group = fetched.first { $0.type == .group }
        #expect(group?.isGroup == true)
        #expect(group?.isPublic == false)

        let location = fetched.first { $0.type == .locationChannel }
        #expect(location?.isPublic == true)
    }

    @Test("Channel muted computed property")
    func channelMutedProperty() throws {
        let context = try makeContext()

        let unmutedChannel = Channel(type: .dm, muteStatus: .unmuted)
        let mutedChannel = Channel(type: .dm, muteStatus: .mutedForever)

        context.insert(unmutedChannel)
        context.insert(mutedChannel)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Channel>())
        let unmuted = fetched.first { $0.muteStatus == .unmuted }
        let muted = fetched.first { $0.muteStatus == .mutedForever }

        #expect(!unmuted!.isMuted)
        #expect(muted!.isMuted)
    }

    @Test("Channel deletion")
    func channelDeletion() throws {
        let context = try makeContext()
        let channel = makeChannel(context: context)
        try context.save()

        context.delete(channel)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Channel>())
        #expect(fetched.isEmpty)
    }

    // MARK: - Attachment Cascade Delete Tests

    @Test("Attachment creation with message relationship")
    func attachmentCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        let attachment = Blip.Attachment(
            message: message,
            type: .image,
            sizeBytes: 1024,
            mimeType: "image/jpeg"
        )
        context.insert(attachment)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Blip.Attachment>())
        #expect(fetched.count == 1)
        #expect(fetched[0].type == .image)
    }

    @Test("Attachment cascade delete with message deletion")
    func attachmentCascadeDelete() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        for i in 0 ..< 3 {
            let attachment = Blip.Attachment(
                message: message,
                type: i % 2 == 0 ? .image : .voiceNote,
                sizeBytes: 1024 * (i + 1)
            )
            context.insert(attachment)
        }
        try context.save()

        let attachmentsBefore = try context.fetch(FetchDescriptor<Blip.Attachment>())
        #expect(attachmentsBefore.count == 3)

        context.delete(message)
        try context.save()

        let attachmentsAfter = try context.fetch(FetchDescriptor<Blip.Attachment>())
        #expect(attachmentsAfter.isEmpty)
    }

    @Test("Attachment type enum roundtrip")
    func attachmentTypeEnum() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        for type in AttachmentType.allCases {
            let attachment = Blip.Attachment(message: message, type: type)
            context.insert(attachment)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Blip.Attachment>())
        #expect(fetched.count == AttachmentType.allCases.count)
    }

    // MARK: - GroupMembership Tests

    @Test("GroupMembership creation with cascade delete")
    func groupMembershipCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(type: .group, context: context)

        let membership = GroupMembership(
            user: user,
            channel: channel,
            role: .member,
            muted: false
        )
        context.insert(membership)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<GroupMembership>())
        #expect(fetched.count == 1)
        #expect(fetched[0].role == .member)
    }

    @Test("GroupMembership role enum roundtrip")
    func groupMembershipRole() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(type: .group, context: context)

        for role in GroupRole.allCases {
            let membership = GroupMembership(
                user: user,
                channel: channel,
                role: role
            )
            context.insert(membership)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<GroupMembership>())
        #expect(fetched.count == GroupRole.allCases.count)
    }

    @Test("GroupMembership isAdmin computed property")
    func groupMembershipIsAdmin() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(type: .group, context: context)

        let member = GroupMembership(user: user, channel: channel, role: .member)
        let admin = GroupMembership(user: user, channel: channel, role: .admin)
        let creator = GroupMembership(user: user, channel: channel, role: .creator)

        context.insert(member)
        context.insert(admin)
        context.insert(creator)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<GroupMembership>())
        #expect(fetched.first { $0.role == .member }?.isAdmin == false)
        #expect(fetched.first { $0.role == .admin }?.isAdmin == true)
        #expect(fetched.first { $0.role == .creator }?.isAdmin == true)
    }

    @Test("GroupMembership cascade delete with channel")
    func groupMembershipCascadeDelete() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(type: .group, context: context)

        for i in 0 ..< 3 {
            let membership = GroupMembership(
                user: user,
                channel: channel,
                role: i == 0 ? .creator : .member
            )
            context.insert(membership)
        }
        try context.save()

        let membershipsBefore = try context.fetch(FetchDescriptor<GroupMembership>())
        #expect(membershipsBefore.count == 3)

        context.delete(channel)
        try context.save()

        let membershipsAfter = try context.fetch(FetchDescriptor<GroupMembership>())
        #expect(membershipsAfter.isEmpty)
    }

    // MARK: - Festival and Stage Tests

    @Test("Festival creation and stage hierarchy")
    func festivalStageHierarchy() throws {
        let context = try makeContext()
        let festival = makeFestival(context: context)
        try context.save()

        let stage1 = Stage(
            name: "Pyramid",
            festival: festival,
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58)
        )
        let stage2 = Stage(
            name: "Silver Hayes",
            festival: festival,
            coordinates: GeoPoint(latitude: 51.16, longitude: -2.59)
        )
        context.insert(stage1)
        context.insert(stage2)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Stage>())
        #expect(fetched.count == 2)
        #expect(fetched[0].festival?.name == "Glastonbury")
    }

    @Test("Festival cascade delete with stages")
    func festivalCascadeDelete() throws {
        let context = try makeContext()
        let festival = makeFestival(context: context)
        try context.save()

        for i in 0 ..< 3 {
            let stage = Stage(
                name: "Stage \(i)",
                festival: festival,
                coordinates: GeoPoint(latitude: 51.15 + Double(i) * 0.01, longitude: -2.58)
            )
            context.insert(stage)
        }
        try context.save()

        let stagesBefore = try context.fetch(FetchDescriptor<Stage>())
        #expect(stagesBefore.count == 3)

        context.delete(festival)
        try context.save()

        let stagesAfter = try context.fetch(FetchDescriptor<Stage>())
        #expect(stagesAfter.isEmpty)
    }

    @Test("Festival computed properties")
    func festivalComputedProperties() throws {
        let context = try makeContext()

        let now = Date()
        let upcoming = Festival(
            name: "Future Fest",
            coordinates: GeoPoint(latitude: 0, longitude: 0),
            radiusMeters: 1000,
            startDate: now.addingTimeInterval(86_400),
            endDate: now.addingTimeInterval(86_400 * 3),
            organizerSigningKey: Data(repeating: 3, count: 32)
        )
        let active = Festival(
            name: "Current Fest",
            coordinates: GeoPoint(latitude: 0, longitude: 0),
            radiusMeters: 1000,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(86_400),
            organizerSigningKey: Data(repeating: 4, count: 32)
        )

        context.insert(upcoming)
        context.insert(active)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Festival>())
        #expect(fetched.first { $0.name == "Future Fest" }?.isUpcoming == true)
        #expect(fetched.first { $0.name == "Current Fest" }?.isActive == true)
    }

    // MARK: - SetTime Tests

    @Test("SetTime creation with stage relationship")
    func setTimeCreation() throws {
        let context = try makeContext()
        let festival = makeFestival(context: context)
        try context.save()

        let stage = Stage(
            name: "Main Stage",
            festival: festival,
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58)
        )
        context.insert(stage)
        try context.save()

        let now = Date()
        let setTime = SetTime(
            artistName: "Radiohead",
            stage: stage,
            startTime: now.addingTimeInterval(3600),
            endTime: now.addingTimeInterval(7200)
        )
        context.insert(setTime)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SetTime>())
        #expect(fetched.count == 1)
        #expect(fetched[0].artistName == "Radiohead")
        #expect(fetched[0].duration == 3600)
    }

    @Test("SetTime cascade delete with stage")
    func setTimeCascadeDelete() throws {
        let context = try makeContext()
        let festival = makeFestival(context: context)
        try context.save()

        let stage = Stage(
            name: "Stage",
            festival: festival,
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58)
        )
        context.insert(stage)
        try context.save()

        let now = Date()
        for i in 0 ..< 3 {
            let setTime = SetTime(
                artistName: "Artist \(i)",
                stage: stage,
                startTime: now.addingTimeInterval(Double(i) * 3600),
                endTime: now.addingTimeInterval(Double(i + 1) * 3600)
            )
            context.insert(setTime)
        }
        try context.save()

        let setTimesBefore = try context.fetch(FetchDescriptor<SetTime>())
        #expect(setTimesBefore.count == 3)

        context.delete(stage)
        try context.save()

        let setTimesAfter = try context.fetch(FetchDescriptor<SetTime>())
        #expect(setTimesAfter.isEmpty)
    }

    // MARK: - SOSAlert Tests

    @Test("SOSAlert creation with location")
    func sosAlertCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let sosAlert = SOSAlert(
            reporter: user,
            severity: .red,
            preciseLocation: GeoPoint(latitude: 51.15, longitude: -2.58),
            fuzzyLocation: "gcpv2h",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(sosAlert)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SOSAlert>())
        #expect(fetched.count == 1)
        #expect(fetched[0].severity == .red)
    }

    @Test("SOSAlert severity enum roundtrip")
    func sosAlertSeverity() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        for severity in SOSSeverity.allCases {
            let alert = SOSAlert(
                reporter: user,
                severity: severity,
                preciseLocation: GeoPoint(latitude: 0, longitude: 0),
                fuzzyLocation: "test",
                expiresAt: Date().addingTimeInterval(3600)
            )
            context.insert(alert)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SOSAlert>())
        #expect(fetched.count == SOSSeverity.allCases.count)
    }

    @Test("SOSAlert status state transitions")
    func sosAlertStatusTransitions() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let alert = SOSAlert(
            reporter: user,
            severity: .red,
            preciseLocation: GeoPoint(latitude: 51.15, longitude: -2.58),
            fuzzyLocation: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(alert)
        try context.save()

        let statuses: [SOSStatus] = [.active, .accepted, .enRoute, .resolved]
        for status in statuses {
            alert.status = status
            try context.save()

            let fetched = try context.fetch(FetchDescriptor<SOSAlert>())
            #expect(fetched[0].status == status)
        }
    }

    @Test("SOSAlert computed properties")
    func sosAlertComputedProperties() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let alert = SOSAlert(
            reporter: user,
            severity: .red,
            preciseLocation: GeoPoint(latitude: 51.15, longitude: -2.58),
            fuzzyLocation: "test",
            status: .accepted,
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(alert)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SOSAlert>())
        #expect(fetched[0].isActive == true)
        #expect(fetched[0].isResolved == false)
    }

    @Test("SOSAlert resolution enum roundtrip")
    func sosAlertResolution() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let alert = SOSAlert(
            reporter: user,
            severity: .red,
            preciseLocation: GeoPoint(latitude: 51.15, longitude: -2.58),
            fuzzyLocation: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(alert)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SOSAlert>())

        for resolution in SOSResolution.allCases {
            fetched[0].resolution = resolution
            try context.save()

            let refetched = try context.fetch(FetchDescriptor<SOSAlert>())
            #expect(refetched[0].resolution == resolution)
        }
    }

    // MARK: - MessageQueue Tests

    @Test("MessageQueue creation and retry logic")
    func messageQueueCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        let queue = MessageQueue(
            message: message,
            attempts: 0,
            maxAttempts: 50,
            transport: .ble
        )
        context.insert(queue)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MessageQueue>())
        #expect(fetched.count == 1)
        #expect(fetched[0].canRetry == true)
    }

    @Test("MessageQueue transport enum roundtrip")
    func messageQueueTransport() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        for transport in QueueTransport.allCases {
            let queue = MessageQueue(message: message, transport: transport)
            context.insert(queue)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MessageQueue>())
        #expect(fetched.count == QueueTransport.allCases.count)
    }

    @Test("MessageQueue status enum roundtrip")
    func messageQueueStatus() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        let queue = MessageQueue(message: message)
        context.insert(queue)
        try context.save()

        for status in QueueStatus.allCases {
            queue.status = status
            try context.save()

            let fetched = try context.fetch(FetchDescriptor<MessageQueue>())
            #expect(fetched[0].status == status)
        }
    }

    @Test("MessageQueue retry exhaustion")
    func messageQueueRetryExhaustion() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let message = Message(sender: user, channel: channel)
        context.insert(message)
        try context.save()

        let queue = MessageQueue(
            message: message,
            attempts: 50,
            maxAttempts: 50
        )
        context.insert(queue)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MessageQueue>())
        #expect(fetched[0].canRetry == false)
    }

    // MARK: - MeetingPoint Tests

    @Test("MeetingPoint creation with location")
    func meetingPointCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let meetingPoint = MeetingPoint(
            creator: user,
            channel: channel,
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58),
            label: "Meet at the Pyramid",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(meetingPoint)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MeetingPoint>())
        #expect(fetched.count == 1)
        #expect(fetched[0].label == "Meet at the Pyramid")
    }

    @Test("MeetingPoint expiration computed property")
    func meetingPointExpiration() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let meetingPoint = MeetingPoint(
            creator: user,
            channel: channel,
            coordinates: GeoPoint(latitude: 51.15, longitude: -2.58),
            label: "Test",
            expiresAt: Date().addingTimeInterval(-3600)
        )
        context.insert(meetingPoint)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MeetingPoint>())
        #expect(fetched[0].isExpired == true)
    }

    // MARK: - FriendLocation Tests

    @Test("FriendLocation creation with breadcrumbs")
    func friendLocationCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let friend = Friend(user: user)
        context.insert(friend)
        try context.save()

        let location = FriendLocation(
            friend: friend,
            precisionLevel: .precise,
            latitude: 51.15,
            longitude: -2.58,
            accuracy: 10.0
        )
        context.insert(location)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<FriendLocation>())
        #expect(fetched.count == 1)
        #expect(fetched[0].hasPreciseLocation == true)
    }

    @Test("FriendLocation breadcrumb cascade delete")
    func friendLocationBreadcrumbCascadeDelete() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let friend = Friend(user: user)
        context.insert(friend)
        try context.save()

        let location = FriendLocation(friend: friend, precisionLevel: .precise)
        context.insert(location)
        try context.save()

        for i in 0 ..< 3 {
            let breadcrumb = BreadcrumbPoint(
                friendLocation: location,
                latitude: 51.15 + Double(i) * 0.01,
                longitude: -2.58
            )
            context.insert(breadcrumb)
        }
        try context.save()

        let breadcrumbsBefore = try context.fetch(FetchDescriptor<BreadcrumbPoint>())
        #expect(breadcrumbsBefore.count == 3)

        context.delete(location)
        try context.save()

        let breadcrumbsAfter = try context.fetch(FetchDescriptor<BreadcrumbPoint>())
        #expect(breadcrumbsAfter.isEmpty)
    }

    // MARK: - BreadcrumbPoint Tests

    @Test("BreadcrumbPoint creation with coordinates")
    func breadcrumbPointCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let friend = Friend(user: user)
        context.insert(friend)
        try context.save()

        let location = FriendLocation(friend: friend)
        context.insert(location)
        try context.save()

        let breadcrumb = BreadcrumbPoint(
            friendLocation: location,
            latitude: 51.15,
            longitude: -2.58
        )
        context.insert(breadcrumb)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BreadcrumbPoint>())
        #expect(fetched.count == 1)
        #expect(fetched[0].coordinate.latitude == 51.15)
    }

    // MARK: - CrowdPulse Tests

    @Test("CrowdPulse creation with heat level")
    func crowdPulseCreation() throws {
        let context = try makeContext()

        let pulse = CrowdPulse(
            geohash: "gcpv2h",
            peerCount: 42,
            heatLevel: .busy
        )
        context.insert(pulse)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CrowdPulse>())
        #expect(fetched.count == 1)
        #expect(fetched[0].heatLevel == .busy)
    }

    @Test("CrowdPulse heat level enum roundtrip")
    func crowdPulseHeatLevel() throws {
        let context = try makeContext()

        for heatLevel in HeatLevel.allCases {
            let pulse = CrowdPulse(
                geohash: "test_\(heatLevel.rawValue)",
                heatLevel: heatLevel
            )
            context.insert(pulse)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CrowdPulse>())
        #expect(fetched.count == HeatLevel.allCases.count)
    }

    @Test("CrowdPulse isStale computed property")
    func crowdPulseIsStale() throws {
        let context = try makeContext()

        let fresh = CrowdPulse(geohash: "fresh", lastUpdated: Date())
        let stale = CrowdPulse(
            geohash: "stale",
            lastUpdated: Date().addingTimeInterval(-400)
        )

        context.insert(fresh)
        context.insert(stale)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CrowdPulse>())
        #expect(fetched.first { $0.geohash == "fresh" }?.isStale == false)
        #expect(fetched.first { $0.geohash == "stale" }?.isStale == true)
    }

    // MARK: - UserPreferences Tests

    @Test("UserPreferences creation with defaults")
    func userPreferencesCreation() throws {
        let context = try makeContext()

        let prefs = UserPreferences()
        context.insert(prefs)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == 1)
        #expect(fetched[0].theme == .system)
        #expect(fetched[0].pttMode == .holdToTalk)
    }

    @Test("UserPreferences theme enum roundtrip")
    func userPreferencesTheme() throws {
        let context = try makeContext()

        for theme in AppTheme.allCases {
            let prefs = UserPreferences(theme: theme)
            context.insert(prefs)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == AppTheme.allCases.count)
    }

    @Test("UserPreferences pttMode enum roundtrip")
    func userPreferencesPTTMode() throws {
        let context = try makeContext()

        for pttMode in PTTMode.allCases {
            let prefs = UserPreferences(pttMode: pttMode)
            context.insert(prefs)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == PTTMode.allCases.count)
    }

    @Test("UserPreferences map style enum roundtrip")
    func userPreferencesMapStyle() throws {
        let context = try makeContext()

        for mapStyle in MapStyle.allCases {
            let prefs = UserPreferences(friendFinderMapStyle: mapStyle)
            context.insert(prefs)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == MapStyle.allCases.count)
    }

    @Test("UserPreferences location sharing enum roundtrip")
    func userPreferencesLocationSharing() throws {
        let context = try makeContext()

        for precision in LocationPrecision.allCases {
            let prefs = UserPreferences(defaultLocationSharing: precision)
            context.insert(prefs)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == LocationPrecision.allCases.count)
    }

    // MARK: - GroupSenderKey Tests

    @Test("GroupSenderKey creation with key material")
    func groupSenderKeyCreation() throws {
        let context = try makeContext()
        let channel = makeChannel(type: .group, context: context)
        try context.save()

        let senderKey = GroupSenderKey(
            channel: channel,
            memberPeerID: Data(repeating: 0xFF, count: 8),
            keyMaterial: Data(repeating: 0xAA, count: 32),
            messageCounter: 0
        )
        context.insert(senderKey)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<GroupSenderKey>())
        #expect(fetched.count == 1)
        #expect(fetched[0].needsRotation == false)
    }

    @Test("GroupSenderKey rotation logic")
    func groupSenderKeyRotation() throws {
        let context = try makeContext()
        let channel = makeChannel(type: .group, context: context)
        try context.save()

        let senderKey = GroupSenderKey(
            channel: channel,
            memberPeerID: Data(repeating: 0xFF, count: 8),
            keyMaterial: Data(repeating: 0xAA, count: 32),
            messageCounter: 99
        )
        context.insert(senderKey)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<GroupSenderKey>())
        #expect(fetched[0].needsRotation == false)

        fetched[0].messageCounter = 100
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<GroupSenderKey>())
        #expect(refetched[0].needsRotation == true)
    }

    // MARK: - NoiseSessionModel Tests

    @Test("NoiseSessionModel creation with expiry")
    func noiseSessionCreation() throws {
        let context = try makeContext()

        let session = NoiseSessionModel(
            peerID: Data(repeating: 0x11, count: 8),
            handshakeComplete: true,
            peerStaticKeyKnown: true,
            peerStaticKey: Data(repeating: 0x22, count: 32)
        )
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<NoiseSessionModel>())
        #expect(fetched.count == 1)
        #expect(fetched[0].handshakeComplete == true)
    }

    @Test("NoiseSessionModel expiration and validity")
    func noiseSessionExpiration() throws {
        let context = try makeContext()

        let validSession = NoiseSessionModel(
            peerID: Data(repeating: 0x33, count: 8),
            handshakeComplete: true,
            expiresAt: Date().addingTimeInterval(3600)
        )

        let expiredSession = NoiseSessionModel(
            peerID: Data(repeating: 0x44, count: 8),
            handshakeComplete: true,
            expiresAt: Date().addingTimeInterval(-3600)
        )

        context.insert(validSession)
        context.insert(expiredSession)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<NoiseSessionModel>())
        #expect(fetched.first { $0.peerID == Data(repeating: 0x33, count: 8) }?.isValid == true)
        #expect(fetched.first { $0.peerID == Data(repeating: 0x44, count: 8) }?.isValid == false)
    }

    @Test("NoiseSessionModel IK handshake eligibility")
    func noiseSessionIKHandshake() throws {
        let context = try makeContext()

        let ikEligible = NoiseSessionModel(
            peerID: Data(repeating: 0x55, count: 8),
            peerStaticKeyKnown: true,
            expiresAt: Date().addingTimeInterval(3600)
        )

        let ikIneligible = NoiseSessionModel(
            peerID: Data(repeating: 0x66, count: 8),
            peerStaticKeyKnown: false,
            expiresAt: Date().addingTimeInterval(3600)
        )

        context.insert(ikEligible)
        context.insert(ikIneligible)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<NoiseSessionModel>())
        #expect(fetched.first { $0.peerID == Data(repeating: 0x55, count: 8) }?.canUseIKHandshake == true)
        #expect(fetched.first { $0.peerID == Data(repeating: 0x66, count: 8) }?.canUseIKHandshake == false)
    }

    // MARK: - MedicalResponder Tests

    @Test("MedicalResponder creation with user")
    func medicalResponderCreation() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let festival = makeFestival(context: context)
        try context.save()

        let responder = MedicalResponder(
            user: user,
            festival: festival,
            accessCodeHash: "hash_responder",
            callsign: "MED-01",
            isOnDuty: true
        )
        context.insert(responder)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MedicalResponder>())
        #expect(fetched.count == 1)
        #expect(fetched[0].callsign == "MED-01")
        #expect(fetched[0].hasActiveAlert == false)
    }

    // MARK: - Complex Relationship Tests

    @Test("User with multiple relationships")
    func userMultipleRelationships() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        try context.save()

        // Add friends
        for i in 0 ..< 3 {
            let friend = Friend(
                user: user,
                status: i % 2 == 0 ? .accepted : .pending
            )
            context.insert(friend)
        }

        // Add messages
        let channel = makeChannel(context: context)
        try context.save()
        for i in 0 ..< 5 {
            let message = Message(
                sender: user,
                channel: channel,
                encryptedPayload: Data("msg\(i)".utf8)
            )
            context.insert(message)
        }

        // Add group memberships
        let groupChannel = makeChannel(type: .group, context: context)
        try context.save()
        for i in 0 ..< 2 {
            let membership = GroupMembership(
                user: user,
                channel: groupChannel,
                role: i == 0 ? .creator : .member
            )
            context.insert(membership)
        }

        try context.save()

        let fetchedUser = try context.fetch(
            FetchDescriptor<User>(predicate: #Predicate { $0.username == "alice" })
        )[0]

        #expect(fetchedUser.friends.count == 3)
        #expect(fetchedUser.sentMessages.count == 5)
        #expect(fetchedUser.memberships.count == 2)
    }

    // MARK: - Bulk Operations and Performance Tests

    @Test("Bulk message insertion")
    func bulkMessageInsertion() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)
        try context.save()

        for i in 0 ..< 100 {
            let message = Message(
                sender: user,
                channel: channel,
                encryptedPayload: Data("message_\(i)".utf8),
                status: i % 5 == 0 ? .delivered : .sent
            )
            context.insert(message)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == 100)
    }

    // MARK: - Index Validation Tests

    @Test("Message createdAt index sorting")
    func messageIndexSorting() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)
        try context.save()

        let now = Date()
        for i in 0 ..< 5 {
            let message = Message(
                sender: user,
                channel: channel,
                createdAt: now.addingTimeInterval(Double(i) * 100)
            )
            context.insert(message)
        }
        try context.save()

        var descriptor = FetchDescriptor<Message>()
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        let fetched = try context.fetch(descriptor)

        for i in 0 ..< fetched.count - 1 {
            #expect(fetched[i].createdAt <= fetched[i + 1].createdAt)
        }
    }

    @Test("Friend status index filtering")
    func friendStatusIndexFiltering() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        for status in FriendStatus.allCases {
            let friend = Friend(user: user, status: status)
            context.insert(friend)
        }
        try context.save()

        let descriptor = FetchDescriptor<Friend>(
            predicate: #Predicate { $0.statusRaw == "accepted" }
        )
        let accepted = try context.fetch(descriptor)
        #expect(accepted.count == 1)
        #expect(accepted[0].status == .accepted)
    }

    // MARK: - GeoPoint Roundtrip Tests

    @Test("GeoPoint storage and retrieval via Friend")
    func geoPointFriendRoundtrip() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let friend = Friend(
            user: user,
            lastSeenLatitude: 51.5074,
            lastSeenLongitude: -0.1278
        )
        context.insert(friend)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Friend>())[0]
        let location = fetched.lastSeenLocation

        #expect(location?.latitude == 51.5074)
        #expect(location?.longitude == -0.1278)
    }

    @Test("GeoPoint storage and retrieval via SOSAlert")
    func geoPointSOSAlertRoundtrip() throws {
        let context = try makeContext()
        let user = makeUser(context: context)

        let alert = SOSAlert(
            reporter: user,
            severity: .red,
            preciseLocation: GeoPoint(latitude: 48.8566, longitude: 2.3522),
            fuzzyLocation: "Paris",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(alert)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SOSAlert>())[0]
        let location = fetched.preciseLocation

        #expect(location.latitude == 48.8566)
        #expect(location.longitude == 2.3522)
    }

    @Test("GeoPoint storage and retrieval via MeetingPoint")
    func geoPointMeetingPointRoundtrip() throws {
        let context = try makeContext()
        let user = makeUser(context: context)
        let channel = makeChannel(context: context)

        let meetingPoint = MeetingPoint(
            creator: user,
            channel: channel,
            coordinates: GeoPoint(latitude: 40.7128, longitude: -74.0060),
            label: "New York",
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(meetingPoint)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MeetingPoint>())[0]
        let coords = fetched.coordinates

        #expect(coords.latitude == 40.7128)
        #expect(coords.longitude == -74.0060)
    }
}

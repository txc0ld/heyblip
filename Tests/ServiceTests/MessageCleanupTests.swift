import XCTest
import SwiftData
@testable import Blip

@MainActor
final class MessageCleanupTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: BlipSchema.schema,
            configurations: [config]
        )
    }

    func testExpiredMessagesAreDeleted() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let channel = Channel(type: .dm, name: "test")
        context.insert(channel)

        // Expired message (expiresAt in the past)
        let expired = Message(
            channel: channel,
            type: .text,
            rawPayload: "old".data(using: .utf8) ?? Data(),
            expiresAt: Date().addingTimeInterval(-60)
        )
        context.insert(expired)

        // Valid message (expiresAt in the future)
        let valid = Message(
            channel: channel,
            type: .text,
            rawPayload: "new".data(using: .utf8) ?? Data(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        context.insert(valid)

        // Message with no expiration
        let noExpiry = Message(
            channel: channel,
            type: .text,
            rawPayload: "forever".data(using: .utf8) ?? Data()
        )
        context.insert(noExpiry)

        try context.save()

        // Verify 3 messages exist
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 3)

        // Run cleanup
        let service = MessageCleanupService(modelContainer: container)
        service.start()

        // Give the sweep time to run (it runs immediately on start)
        let expectation = expectation(description: "sweep completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        service.stop()

        // Expired should be gone, valid + noExpiry should remain
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 2)
    }

    func testRetentionPolicyDeletesOldMessages() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Channel with 1-hour retention
        let channel = Channel(type: .dm, name: "retention-test", maxRetention: 3600)
        context.insert(channel)

        // Message older than retention (2 hours ago)
        let old = Message(
            channel: channel,
            type: .text,
            rawPayload: "old".data(using: .utf8) ?? Data(),
            createdAt: Date().addingTimeInterval(-7200)
        )
        context.insert(old)

        // Recent message (10 minutes ago)
        let recent = Message(
            channel: channel,
            type: .text,
            rawPayload: "recent".data(using: .utf8) ?? Data(),
            createdAt: Date().addingTimeInterval(-600)
        )
        context.insert(recent)

        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 2)

        let service = MessageCleanupService(modelContainer: container)
        service.start()

        let expectation = expectation(description: "sweep completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        service.stop()

        let remaining = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(String(data: remaining[0].rawPayload, encoding: .utf8), "recent")
    }

    func testInfiniteRetentionKeepsAllMessages() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Channel with default (infinite) retention
        let channel = Channel(type: .dm, name: "infinite-test")
        context.insert(channel)

        // Very old message
        let old = Message(
            channel: channel,
            type: .text,
            rawPayload: "ancient".data(using: .utf8) ?? Data(),
            createdAt: Date().addingTimeInterval(-86400 * 365)
        )
        context.insert(old)
        try context.save()

        let service = MessageCleanupService(modelContainer: container)
        service.start()

        let expectation = expectation(description: "sweep completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        service.stop()

        // Should still be there — infinite retention means no cleanup
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 1)
    }
}

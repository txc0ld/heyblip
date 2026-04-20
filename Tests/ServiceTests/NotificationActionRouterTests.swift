import XCTest
@testable import Blip

@MainActor
final class NotificationActionRouterTests: XCTestCase {
    func testHandleAction_openConversation_returnsConversationDestination() async {
        let router = NotificationActionRouter(
            dependencies: .init(
                fetchChannel: { _ in nil },
                fetchFriend: { _ in nil },
                markChannelAsRead: { _ in },
                toggleMute: { _ in },
                acceptFriendRequest: { _ in },
                declineFriendRequest: { _ in },
                visibleAlert: { _ in nil },
                acceptAlert: { _ in },
                sendTextMessage: { _, _ in },
                createDMDestination: { _ in nil }
            )
        )

        let channelID = UUID()
        let destination = await router.handleAction(
            .openConversation,
            userInfo: ["channelID": channelID.uuidString]
        )

        XCTAssertEqual(destination, .conversation(channelID: channelID))
    }

    func testHandleAction_markRead_fetchesChannelAndInvokesDependency() async {
        let channel = Channel(type: .dm, name: "DM")
        var markedChannels: [UUID] = []

        let router = NotificationActionRouter(
            dependencies: .init(
                fetchChannel: { id in
                    id == channel.id ? channel : nil
                },
                fetchFriend: { _ in nil },
                markChannelAsRead: { markedChannels.append($0.id) },
                toggleMute: { _ in },
                acceptFriendRequest: { _ in },
                declineFriendRequest: { _ in },
                visibleAlert: { _ in nil },
                acceptAlert: { _ in },
                sendTextMessage: { _, _ in },
                createDMDestination: { _ in nil }
            )
        )

        let destination = await router.handleAction(
            .markRead,
            userInfo: ["channelID": channel.id.uuidString]
        )

        XCTAssertNil(destination)
        XCTAssertEqual(markedChannels, [channel.id])
    }

    func testHandleReply_sendsTextMessageForFetchedChannel() async {
        let channel = Channel(type: .dm, name: "DM")
        var sentPayloads: [(String, UUID)] = []

        let router = NotificationActionRouter(
            dependencies: .init(
                fetchChannel: { id in
                    id == channel.id ? channel : nil
                },
                fetchFriend: { _ in nil },
                markChannelAsRead: { _ in },
                toggleMute: { _ in },
                acceptFriendRequest: { _ in },
                declineFriendRequest: { _ in },
                visibleAlert: { _ in nil },
                acceptAlert: { _ in },
                sendTextMessage: { text, channel in
                    sentPayloads.append((text, channel.id))
                },
                createDMDestination: { _ in nil }
            )
        )

        await router.handleReply(
            text: "hello",
            userInfo: ["channelID": channel.id.uuidString]
        )

        XCTAssertEqual(sentPayloads.map(\.0), ["hello"])
        XCTAssertEqual(sentPayloads.map(\.1), [channel.id])
    }

    func testOpenDM_returnsDependencyDestination() async {
        let channelID = UUID()
        let router = NotificationActionRouter(
            dependencies: .init(
                fetchChannel: { _ in nil },
                fetchFriend: { _ in nil },
                markChannelAsRead: { _ in },
                toggleMute: { _ in },
                acceptFriendRequest: { _ in },
                declineFriendRequest: { _ in },
                visibleAlert: { _ in nil },
                acceptAlert: { _ in },
                sendTextMessage: { _, _ in },
                createDMDestination: { username in
                    XCTAssertEqual(username, "alice")
                    return .conversation(channelID: channelID)
                }
            )
        )

        let destination = await router.openDM(withUsername: "alice")

        XCTAssertEqual(destination, .conversation(channelID: channelID))
    }
}

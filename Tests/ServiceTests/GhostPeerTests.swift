import XCTest
@testable import Blip

final class GhostPeerTests: XCTestCase {

    func testDisconnectMarksPeerAsDisconnected() {
        let peerStore = PeerStore()
        let peerData = Data([0x1a, 0x8b, 0x34, 0x5f, 0x00, 0x00, 0x00, 0x01])

        // Simulate a connected peer
        let info = PeerInfo(
            peerID: peerData,
            noisePublicKey: Data(),
            signingPublicKey: Data(),
            username: "ghost",
            rssi: -60,
            isConnected: true,
            lastSeenAt: Date(),
            hopCount: 0
        )
        peerStore.upsert(peer: info)

        // PeerStore uses barrier async — give it time to process
        let upsertExpectation = expectation(description: "upsert completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            upsertExpectation.fulfill()
        }
        wait(for: [upsertExpectation], timeout: 1.0)

        // Verify connected
        XCTAssertEqual(peerStore.connectedPeers().count, 1)

        // Simulate disconnect
        peerStore.markDisconnected(peerID: peerData)

        // Give barrier async time to process
        let disconnectExpectation = expectation(description: "disconnect completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        // Verify no longer connected
        XCTAssertEqual(peerStore.connectedPeers().count, 0)

        // Verify peer still exists but is disconnected
        guard let peer = peerStore.peer(for: peerData) else {
            XCTFail("Peer should still exist after disconnect")
            return
        }
        XCTAssertFalse(peer.isConnected)
        XCTAssertEqual(peer.username, "ghost")
    }

    func testMultiplePeersOnlyTargetDisconnects() {
        let peerStore = PeerStore()
        let peer1 = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let peer2 = Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])

        peerStore.upsert(peer: PeerInfo(
            peerID: peer1, noisePublicKey: Data(), signingPublicKey: Data(),
            username: "alice", rssi: -50, isConnected: true, lastSeenAt: Date(), hopCount: 1
        ))
        peerStore.upsert(peer: PeerInfo(
            peerID: peer2, noisePublicKey: Data(), signingPublicKey: Data(),
            username: "bob", rssi: -60, isConnected: true, lastSeenAt: Date(), hopCount: 1
        ))

        let setupExpectation = expectation(description: "setup completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { setupExpectation.fulfill() }
        wait(for: [setupExpectation], timeout: 1.0)

        XCTAssertEqual(peerStore.connectedPeers().count, 2)

        // Disconnect only peer1
        peerStore.markDisconnected(peerID: peer1)

        let disconnectExpectation = expectation(description: "disconnect completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { disconnectExpectation.fulfill() }
        wait(for: [disconnectExpectation], timeout: 1.0)

        XCTAssertEqual(peerStore.connectedPeers().count, 1)
        XCTAssertEqual(peerStore.connectedPeers().first?.username, "bob")
    }
}

import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import BlipMesh
import BlipProtocol

private func makeRetryTestPeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data(repeating: byte, count: PeerID.length))!
}

private func makeRunningCoordinator() -> (coordinator: TransportCoordinator, ble: BLEService, delegate: MockTransportDelegate) {
    let central = MockBLECentralManager()
    central.cmState = .poweredOn

    let peripheral = MockBLEPeripheralManager()
    peripheral.pmState = .poweredOn

    let delegate = MockTransportDelegate()
    let localPeerID = makeRetryTestPeerID(0xAA)
    let ble = BLEService(
        localPeerID: localPeerID,
        centralManager: central,
        peripheralManager: peripheral
    )
    let webSocket = WebSocketTransport(
        localPeerID: localPeerID,
        pinnedCertHashes: [],
        pinnedDomains: [],
        tokenProvider: { "test-token" },
        relayURL: URL(string: "ws://localhost")!
    )
    let coordinator = TransportCoordinator(bleTransport: ble, webSocketTransport: webSocket)
    coordinator.delegate = delegate

    ble.start()
    ble.handleCentralStateChange(.poweredOn)
    ble.handlePeripheralManagerStateChange(.poweredOn)

    return (coordinator, ble, delegate)
}

@Suite("TransportCoordinator retry exhaustion")
struct TransportCoordinatorRetryTests {
    @Test("Queued direct message notifies delegate after max retries")
    func queuedMessageFailureCallback() throws {
        let (coordinator, ble, delegate) = makeRunningCoordinator()
        let targetPeer = makeRetryTestPeerID(0x11)
        let triggerPeer = makeRetryTestPeerID(0x22)
        let payload = Data("failed-after-retries".utf8)

        coordinator.send(data: payload, to: targetPeer)
        #expect(coordinator.localQueueCount == 1)

        for _ in 0...TransportCoordinator.maxRetries {
            coordinator.transport(ble, didConnect: triggerPeer)
            Thread.sleep(forTimeInterval: 0.02)
        }

        #expect(coordinator.localQueueCount == 0)
        #expect(delegate.failedDeliveries.count == 1)
        #expect(delegate.failedDeliveries[0].data == payload)
        #expect(delegate.failedDeliveries[0].to == targetPeer)
    }
}

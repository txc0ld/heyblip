import XCTest
import SwiftData
@testable import Blip
import BlipMesh
import BlipProtocol

/// Tests for `MeshViewModel.refreshMeshState`, with a focus on the BDEV-438
/// regression: a connected BLE peer whose first `peripheral.readRSSI()`
/// sample hasn't arrived yet carries `rssi == Int.min` (the
/// `PeerInfo.noSignalRSSI` sentinel). The previous reduce summed every
/// connected peer's `rssi` unconditionally, which underflow-traps the
/// process when the running sum hits `Int.min` and another negative dBm
/// value is added — surfaces in Sentry as `EXC_BREAKPOINT 'overflow'`
/// (APPLE-IOS-28).
@MainActor
final class MeshViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var peerStore: PeerStore!
    private var vm: MeshViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])
        peerStore = PeerStore()
        vm = MeshViewModel(modelContainer: container, peerStore: peerStore)
    }

    override func tearDown() async throws {
        container = nil
        peerStore = nil
        vm = nil
    }

    // MARK: - BDEV-438

    /// A connected BLE peer with `rssi == Int.min` (no signal sample yet)
    /// alongside a peer with a real sample must not trap, and the average
    /// must be computed only over peers with valid signal data.
    func test_refreshMeshState_excludesNoSignalPeersFromAverageRSSI() async {
        peerStore.upsert(peer: makePeer(
            peerIDByte: 0x01,
            noiseByte: 0xaa,
            rssi: PeerInfo.noSignalRSSI
        ))
        peerStore.upsert(peer: makePeer(
            peerIDByte: 0x02,
            noiseByte: 0xcc,
            rssi: -55
        ))

        await vm.refreshMeshState()

        XCTAssertEqual(
            vm.averageRSSI, -55,
            "Average RSSI must exclude peers whose RSSI sample is the noSignalRSSI sentinel"
        )
        XCTAssertEqual(
            vm.connectedPeerCount, 2,
            "Both connected BLE peers should be reflected in the count even when one lacks signal"
        )
    }

    /// When every connected BLE peer is in the pre-signal-sample window the
    /// reduce would otherwise trap on `Int.min`. Verify we fall back to the
    /// existing `-100` floor instead.
    func test_refreshMeshState_fallsBackToFloorWhenNoPeerHasSignal() async {
        peerStore.upsert(peer: makePeer(
            peerIDByte: 0x03,
            noiseByte: 0xee,
            rssi: PeerInfo.noSignalRSSI
        ))

        await vm.refreshMeshState()

        XCTAssertEqual(
            vm.averageRSSI, -100,
            "Falls back to the -100 floor when no peer has reported a signal sample"
        )
        XCTAssertEqual(vm.connectedPeerCount, 1)
    }

    /// Sanity check: with two real samples the average is computed normally.
    func test_refreshMeshState_averagesOverValidSamples() async {
        peerStore.upsert(peer: makePeer(
            peerIDByte: 0x04,
            noiseByte: 0x11,
            rssi: -40
        ))
        peerStore.upsert(peer: makePeer(
            peerIDByte: 0x05,
            noiseByte: 0x22,
            rssi: -60
        ))

        await vm.refreshMeshState()

        XCTAssertEqual(vm.averageRSSI, -50)
        XCTAssertEqual(vm.connectedPeerCount, 2)
    }

    // MARK: - Fixture

    private func makePeer(peerIDByte: UInt8, noiseByte: UInt8, rssi: Int) -> PeerInfo {
        PeerInfo(
            peerID: Data(repeating: peerIDByte, count: 8),
            noisePublicKey: Data(repeating: noiseByte, count: 32),
            signingPublicKey: Data(repeating: noiseByte, count: 32),
            username: "peer-\(peerIDByte)",
            rssi: rssi,
            isConnected: true,
            lastSeenAt: Date(),
            hopCount: 1,
            lastAnnounceTimestamp: 0,
            transportType: .bluetooth
        )
    }
}

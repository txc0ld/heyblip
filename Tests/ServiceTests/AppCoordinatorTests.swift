import XCTest
import SwiftData
@testable import Blip
@testable import BlipCrypto
@testable import BlipMesh

// MARK: - AppCoordinatorTests

/// Tests for AppCoordinator initialization, identity loading, and cleanup flows.
///
/// Uses an InMemoryKeyManagerStore to control whether an identity is present,
/// isolating tests from the real iOS Keychain.
@MainActor
final class AppCoordinatorTests: XCTestCase {

    // MARK: - Identity Loading

    func testInitWithIdentity_setsIsReady() throws {
        // Store an identity in the in-memory key store before creating the coordinator.
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)

        // With a valid identity, the coordinator should NOT need onboarding.
        XCTAssertFalse(coordinator.needsOnboarding, "Should not need onboarding when identity exists")
        XCTAssertNil(coordinator.initError, "No init error expected")
        XCTAssertNotNil(coordinator.identity, "Identity should be loaded")
        XCTAssertNotNil(coordinator.localPeerID, "PeerID should be derived from identity")
    }

    func testInitWithoutIdentity_setsNeedsOnboarding() {
        // Empty key store — no identity available.
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())

        let coordinator = AppCoordinator(keyManager: keyManager)

        XCTAssertTrue(coordinator.needsOnboarding, "Should need onboarding when no identity exists")
        XCTAssertNil(coordinator.identity, "Identity should be nil")
        XCTAssertNil(coordinator.localPeerID, "PeerID should be nil")
    }

    // MARK: - Stop and Cleanup

    func testStop_cleansUpTimersAndServices() throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)

        // Configure with an in-memory container to create services
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])
        coordinator.configure(modelContainer: container)

        XCTAssertTrue(coordinator.isReady, "Coordinator should be ready after configure")
        XCTAssertNotNil(coordinator.messageService, "MessageService should be created")
        XCTAssertNotNil(coordinator.chatViewModel, "ChatViewModel should be created")

        // Stop should clean up without crashing
        coordinator.stop()

        // After stop, messageCleanupService should be stopped (no crash on re-stop)
        coordinator.stop() // Double-stop should be safe
    }

    func testConfigureWithoutIdentity_doesNotCreateServices() {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let coordinator = AppCoordinator(keyManager: keyManager)

        // Try to configure without an identity — should bail out safely
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])
            coordinator.configure(modelContainer: container)
        } catch {
            XCTFail("ModelContainer creation should not fail: \(error)")
        }

        XCTAssertFalse(coordinator.isReady, "Should not be ready without identity")
        XCTAssertNil(coordinator.messageService, "MessageService should not be created without identity")
        XCTAssertNil(coordinator.chatViewModel, "ChatViewModel should not be created without identity")
    }

    func testConfigureTwice_rebuildsRuntime() throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        coordinator.configure(modelContainer: container)
        let firstRuntime = try XCTUnwrap(coordinator.runtime)
        let firstMessageService = try XCTUnwrap(coordinator.messageService)

        coordinator.configure(modelContainer: container)
        let secondRuntime = try XCTUnwrap(coordinator.runtime)
        let secondMessageService = try XCTUnwrap(coordinator.messageService)

        XCTAssertTrue(coordinator.isReady, "Coordinator should remain ready after reconfigure")
        XCTAssertFalse(firstRuntime === secondRuntime, "Runtime should be rebuilt on reconfigure")
        XCTAssertFalse(firstMessageService === secondMessageService, "Runtime-owned services should be rebuilt on reconfigure")
    }

    func testResetToOnboarding_clearsRuntimeServices() throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        coordinator.configure(modelContainer: container)
        XCTAssertNotNil(coordinator.runtime, "Runtime should exist after configure")

        coordinator.resetToOnboarding()

        XCTAssertNil(coordinator.runtime, "Runtime should be cleared during onboarding reset")
        XCTAssertNil(coordinator.messageService, "MessageService should no longer be reachable after reset")
        XCTAssertNil(coordinator.chatViewModel, "ChatViewModel should no longer be reachable after reset")
        XCTAssertNil(coordinator.identity, "Identity should be cleared during onboarding reset")
        XCTAssertNil(coordinator.localPeerID, "PeerID should be cleared during onboarding reset")
        XCTAssertFalse(coordinator.isReady, "Coordinator should no longer be ready after reset")
        XCTAssertTrue(coordinator.needsOnboarding, "Reset should return the app to onboarding")
    }

    // MARK: - Reconfigure After Onboarding

    func testReconfigureAfterOnboarding_withIdentity_becomesReady() throws {
        let keyStore = InMemoryKeyManagerStore()
        let keyManager = KeyManager(keyStore: keyStore)

        // Start without identity
        let coordinator = AppCoordinator(keyManager: keyManager)
        XCTAssertTrue(coordinator.needsOnboarding)

        // Simulate onboarding: generate and store identity
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        let success = coordinator.reconfigureAfterOnboarding(modelContainer: container)

        XCTAssertTrue(success, "Reconfigure should succeed after storing identity")
        XCTAssertTrue(coordinator.isReady, "Should be ready after reconfigure")
        XCTAssertFalse(coordinator.needsOnboarding, "Should no longer need onboarding")
    }

    func testReconfigureAfterOnboarding_withoutIdentity_remainsNotReady() throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let coordinator = AppCoordinator(keyManager: keyManager)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        // Reconfigure without actually storing an identity
        let success = coordinator.reconfigureAfterOnboarding(modelContainer: container)

        XCTAssertFalse(success, "Reconfigure should fail without identity")
        XCTAssertFalse(coordinator.isReady, "Should not be ready")
    }

    // MARK: - Live Transport State Mirroring (HEY-1305)

    func testTransportDelegate_mirrorsWebSocketStateOntoCoordinator() async throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])
        coordinator.configure(modelContainer: container)
        defer { coordinator.stop() }

        let webSocketTransport = try XCTUnwrap(coordinator.webSocketTransport)

        XCTAssertEqual(coordinator.webSocketTransportState, .idle, "Should start idle before any state events")

        coordinator.transport(webSocketTransport, didChangeState: .starting)
        try await waitForState(.starting) { coordinator.webSocketTransportState }

        coordinator.transport(webSocketTransport, didChangeState: .running)
        try await waitForState(.running) { coordinator.webSocketTransportState }

        coordinator.transport(webSocketTransport, didChangeState: .stopped)
        try await waitForState(.stopped) { coordinator.webSocketTransportState }
    }

    func testTransportDelegate_mirrorsBLEStateOntoCoordinator() async throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        let coordinator = AppCoordinator(keyManager: keyManager)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BlipSchema.schema, configurations: [config])
        coordinator.configure(modelContainer: container)
        defer { coordinator.stop() }

        let bleService = try XCTUnwrap(coordinator.bleService)

        XCTAssertEqual(coordinator.bleTransportState, .idle, "Should start idle before any state events")

        coordinator.transport(bleService, didChangeState: .starting)
        try await waitForState(.starting) { coordinator.bleTransportState }

        coordinator.transport(bleService, didChangeState: .running)
        try await waitForState(.running) { coordinator.bleTransportState }

        coordinator.transport(bleService, didChangeState: .unauthorized)
        try await waitForState(.unauthorized) { coordinator.bleTransportState }
    }

    func testBLEDebugLabels_renderTransportStates() {
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .idle, hasService: true), "Idle")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .starting, hasService: true), "Starting")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .running, hasService: true), "Running")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .stopped, hasService: true), "Stopped")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .unauthorized, hasService: true), "Unauthorized")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .failed("oops"), hasService: true), "Failed: oops")
        XCTAssertEqual(BLEDebugOverlay.bleLabel(for: .running, hasService: false), "Not initialized")

        XCTAssertEqual(BLEDebugOverlay.webSocketLabel(for: .running), "Connected")
        XCTAssertEqual(BLEDebugOverlay.webSocketLabel(for: .starting), "Connecting")
        XCTAssertEqual(BLEDebugOverlay.webSocketLabel(for: .idle), "Disconnected")
        XCTAssertEqual(BLEDebugOverlay.webSocketLabel(for: .stopped), "Disconnected")
        XCTAssertEqual(BLEDebugOverlay.webSocketLabel(for: .failed("nope")), "Disconnected")
    }

    /// The TransportDelegate mirror hops to MainActor via `Task { @MainActor }`.
    /// Yield until either the property reaches the expected value or the deadline
    /// elapses — keeps the assertion deterministic without relying on a fixed sleep.
    private func waitForState(
        _ expected: TransportState,
        timeout: TimeInterval = 1.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ probe: () -> TransportState
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while probe() != expected {
            if Date() > deadline {
                XCTFail("Timed out waiting for state \(expected); last seen: \(probe())", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

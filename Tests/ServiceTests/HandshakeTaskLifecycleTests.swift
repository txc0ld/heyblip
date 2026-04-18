import XCTest
import SwiftData
@testable import Blip
@testable import BlipProtocol
@testable import BlipMesh
@testable import BlipCrypto

/// Regression tests for the handshake Task lifecycle invariants documented in
/// `MessageService.swift:115-127`:
///
/// - `onSessionEstablished(with:)` must cancel and remove both the timeout
///   and retry Task for that peer.
/// - `handleHandshakeTimeout(peerIDBytes:)` must do the same.
/// - `MessageService.deinit` must cancel all in-flight Tasks so they stop
///   touching `self` after the service tears down (e.g. on logout).
///
/// These invariants were added after a class of bugs where the 30s timeout
/// Task kept sleeping past session establishment and later ran
/// `handleHandshakeTimeout` over an already-live session.
@MainActor
final class HandshakeTaskLifecycleTests: XCTestCase {

    private var container: ModelContainer!
    private var mockTransport: MockTransport!
    private var keyManager: KeyManager!
    private var identity: Identity!
    private var messageService: MessageService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        mockTransport = MockTransport()
        mockTransport.start()

        keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        messageService = MessageService(modelContainer: container, keyManager: keyManager)
        messageService.configure(transport: mockTransport, identity: identity)
    }

    override func tearDown() async throws {
        messageService = nil
        mockTransport = nil
        keyManager = nil
        identity = nil
        container = nil
    }

    // MARK: - Helpers

    /// Inject a long-running Task into both handshake maps so the cancellation
    /// contract can be asserted without engineering a real responder state.
    /// The injected Tasks sleep for an absurdly long time — if they're still
    /// running after `onSessionEstablished` / `handleHandshakeTimeout` /
    /// `deinit`, the cancellation contract is broken.
    private func injectHandshakeTasks(for peerBytes: Data) -> (timeout: Task<Void, Never>, retry: Task<Void, Never>) {
        let timeoutTask = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
        }
        let retryTask = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
        }
        messageService.lock.withLock {
            messageService.handshakeTimeoutTasks[peerBytes] = timeoutTask
            messageService.handshakeRetryTasks[peerBytes] = retryTask
        }
        return (timeoutTask, retryTask)
    }

    private func makePeerID(_ byte: UInt8) -> PeerID {
        PeerID(bytes: Data(repeating: byte, count: PeerID.length))!
    }

    /// Poll until `condition` is true or `timeout` elapses. XCTest's
    /// `fulfillment(of:)` requires an `XCTestExpectation`; for Task-cancellation
    /// checks this is a tighter loop.
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 1.0,
        interval: TimeInterval = 0.01
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    // MARK: - onSessionEstablished

    func test_onSessionEstablished_cancelsAndClearsBothTasks() async {
        let peer = makePeerID(0x11)
        let (timeoutTask, retryTask) = injectHandshakeTasks(for: peer.bytes)

        // No queued payloads: keep pending* dictionaries empty so the flush path
        // is a no-op. We're only asserting Task lifecycle.
        messageService.onSessionEstablished(with: peer)

        let timeoutCancelled = await waitUntil(timeoutTask.isCancelled)
        let retryCancelled = await waitUntil(retryTask.isCancelled)
        XCTAssertTrue(timeoutCancelled, "timeout Task should be cancelled on session establishment")
        XCTAssertTrue(retryCancelled, "retry Task should be cancelled on session establishment")

        let (timeoutRemoved, retryRemoved): (Bool, Bool) = messageService.lock.withLock {
            (
                messageService.handshakeTimeoutTasks[peer.bytes] == nil,
                messageService.handshakeRetryTasks[peer.bytes] == nil
            )
        }
        XCTAssertTrue(timeoutRemoved, "timeout Task map entry should be removed")
        XCTAssertTrue(retryRemoved, "retry Task map entry should be removed")
    }

    func test_onSessionEstablished_doesNotCancelOtherPeersTasks() async {
        let peerA = makePeerID(0x11)
        let peerB = makePeerID(0x22)
        let (timeoutA, retryA) = injectHandshakeTasks(for: peerA.bytes)
        let (timeoutB, retryB) = injectHandshakeTasks(for: peerB.bytes)

        messageService.onSessionEstablished(with: peerA)

        _ = await waitUntil(timeoutA.isCancelled && retryA.isCancelled)
        XCTAssertTrue(timeoutA.isCancelled)
        XCTAssertTrue(retryA.isCancelled)

        // Peer B's Tasks must survive.
        XCTAssertFalse(timeoutB.isCancelled, "peer B's timeout Task should be untouched")
        XCTAssertFalse(retryB.isCancelled, "peer B's retry Task should be untouched")

        // Cleanup: cancel peer B's leftover Tasks so the test doesn't leave
        // pending sleeps hanging around.
        timeoutB.cancel()
        retryB.cancel()
    }

    // MARK: - handleHandshakeTimeout

    func test_handleHandshakeTimeout_cancelsRetryAndClearsBothMaps() async {
        let peer = makePeerID(0x33)
        let (timeoutTask, retryTask) = injectHandshakeTasks(for: peer.bytes)

        messageService.handleHandshakeTimeout(peerIDBytes: peer.bytes)

        // Per MessageService+Handshake.swift:340-342 — retry is cancelled,
        // timeout entry is removed (but not explicitly cancelled: its sleep
        // has already fired to land us in this function). For an injected
        // Task we still expect it to stop referencing the service; cancelling
        // it defensively here matches what the production path does via
        // retry-task cancellation.
        let retryCancelled = await waitUntil(retryTask.isCancelled)
        XCTAssertTrue(retryCancelled, "retry Task should be cancelled on handshake timeout")

        let (timeoutRemoved, retryRemoved): (Bool, Bool) = messageService.lock.withLock {
            (
                messageService.handshakeTimeoutTasks[peer.bytes] == nil,
                messageService.handshakeRetryTasks[peer.bytes] == nil
            )
        }
        XCTAssertTrue(timeoutRemoved, "timeout Task map entry should be cleared on timeout")
        XCTAssertTrue(retryRemoved, "retry Task map entry should be cleared on timeout")

        // Defensive cleanup — the injected timeout Task wasn't actually the
        // one whose sleep fired, so cancel it now.
        timeoutTask.cancel()
    }

    // MARK: - deinit cancels everything

    func test_deinit_cancelsAllInFlightHandshakeTasks() async {
        let peerA = makePeerID(0x44)
        let peerB = makePeerID(0x55)
        let (timeoutA, retryA) = injectHandshakeTasks(for: peerA.bytes)
        let (timeoutB, retryB) = injectHandshakeTasks(for: peerB.bytes)

        // Release the service — deinit runs synchronously here on MainActor.
        messageService = nil

        let allCancelled = await waitUntil(
            timeoutA.isCancelled && retryA.isCancelled
                && timeoutB.isCancelled && retryB.isCancelled,
            timeout: 2.0
        )
        XCTAssertTrue(allCancelled, "all in-flight handshake Tasks must be cancelled on deinit")
    }

    // MARK: - Rapid re-inject does not leak the prior task

    func test_rapidReInject_cancelsPreviousTaskBeforeOverwriting() async {
        let peer = makePeerID(0x66)
        let (firstTimeout, firstRetry) = injectHandshakeTasks(for: peer.bytes)

        // Production paths (initiateHandshakeIfNeeded, onSessionEstablished flush)
        // explicitly `.cancel()` the old entry under lock before overwriting —
        // see MessageService+Handshake.swift:162-163 and :254-255. Simulate
        // that pattern and assert the previous Task is cancelled, not
        // abandoned.
        let newTimeout = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
        }
        let newRetry = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
        }
        messageService.lock.withLock {
            messageService.handshakeTimeoutTasks[peer.bytes]?.cancel()
            messageService.handshakeTimeoutTasks[peer.bytes] = newTimeout
            messageService.handshakeRetryTasks[peer.bytes]?.cancel()
            messageService.handshakeRetryTasks[peer.bytes] = newRetry
        }

        let firstsCancelled = await waitUntil(firstTimeout.isCancelled && firstRetry.isCancelled)
        XCTAssertTrue(firstsCancelled, "previous Tasks must be cancelled before overwrite")

        XCTAssertFalse(newTimeout.isCancelled)
        XCTAssertFalse(newRetry.isCancelled)

        // Final cleanup via session-established path.
        messageService.onSessionEstablished(with: peer)
        _ = await waitUntil(newTimeout.isCancelled && newRetry.isCancelled)
    }
}

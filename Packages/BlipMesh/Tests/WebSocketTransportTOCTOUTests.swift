import Testing
import Foundation
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makeWSPeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data(repeating: byte, count: PeerID.length))!
}

private func makeWebSocketTransport(
    tokenProvider: @escaping @Sendable () async throws -> String = { "test-token" },
    tokenRefreshHandler: (@Sendable () async throws -> Void)? = nil
) -> WebSocketTransport {
    WebSocketTransport(
        localPeerID: makeWSPeerID(0xAA),
        pinnedCertHashes: [],
        pinnedDomains: [],
        tokenProvider: tokenProvider,
        tokenRefreshHandler: tokenRefreshHandler,
        // Unreachable address so the URLSession task never actually connects
        // during these tests — we only exercise the state machine.
        relayURL: URL(string: "ws://127.0.0.1:1")!
    )
}

/// Regression suite for the `send`/`broadcast` TOCTOU invariant described in
/// `WebSocketTransport.send(data:to:)`: state and the active WebSocket task
/// must be captured under a single lock acquisition, otherwise a concurrent
/// `stop()` can land between the checks and we end up either crashing on a
/// stale task or, worse, silently falling back to broadcast in the mesh layer.
@Suite("WebSocketTransport TOCTOU + delivery contract")
struct WebSocketTransportTOCTOUTests {

    // MARK: State machine contract

    @Test("send throws .notStarted from idle state")
    func sendThrowsFromIdle() {
        let transport = makeWebSocketTransport()
        #expect(transport.state == .idle)

        #expect(throws: TransportError.notStarted) {
            try transport.send(data: Data("hello".utf8), to: makeWSPeerID(0x11))
        }
    }

    @Test("broadcast from idle state is silently dropped (no crash, no delegate callback)")
    func broadcastFromIdleIsDropped() {
        let transport = makeWebSocketTransport()
        let delegate = MockTransportDelegate()
        transport.delegate = delegate

        transport.broadcast(data: Data("ignored".utf8))

        // Broadcast requires state == .running; from idle it should just
        // drop. didFailDelivery is only invoked by the task.send callback,
        // which we never reached.
        #expect(delegate.failedDeliveries.isEmpty)
    }

    @Test("stop() from idle transitions to .stopped and blocks subsequent sends")
    func stopFromIdleStopsFurtherSends() {
        let transport = makeWebSocketTransport()
        let delegate = MockTransportDelegate()
        transport.delegate = delegate

        transport.stop()
        #expect(transport.state == .stopped)

        #expect(throws: TransportError.notStarted) {
            try transport.send(data: Data("after-stop".utf8), to: makeWSPeerID(0x22))
        }
    }

    @Test("connectedPeers is empty while not connected")
    func connectedPeersEmptyBeforeConnect() {
        let transport = makeWebSocketTransport()
        #expect(transport.connectedPeers.isEmpty)

        transport.stop()
        #expect(transport.connectedPeers.isEmpty)
    }

    // MARK: TOCTOU: concurrent send + stop must be safe

    @Test("Concurrent send + stop never crashes and always surfaces an error for unstarted sends")
    func concurrentSendStopIsSafe() async throws {
        // The point of this test is not to prove the lock is used (which is
        // a static property of the code), but to exercise the race path
        // under TSan / normal execution and assert no send silently succeeds.
        // Every send attempt before/around stop must throw, because the
        // transport never reached .running (no real relay).
        let transport = makeWebSocketTransport()
        transport.start()

        let peer = makeWSPeerID(0x33)
        let payload = Data("race".utf8)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    do {
                        try transport.send(data: payload, to: peer)
                        // A send cannot succeed without a real relay. If it
                        // ever does, the state machine is broken.
                        return false
                    } catch {
                        return true
                    }
                }
            }
            group.addTask {
                transport.stop()
                return true
            }

            for await threwOrStopped in group {
                #expect(threwOrStopped, "every send must throw; no silent success path")
            }
        }

        #expect(transport.state == .stopped)
    }

    // MARK: Token provider failure does not corrupt the state machine

    @Test("A throwing tokenProvider + stop leaves the transport in .stopped (autoReconnect off)")
    func throwingTokenProviderFollowedByStop() async {
        struct AuthError: Error {}
        let transport = makeWebSocketTransport(tokenProvider: { throw AuthError() })

        transport.start()

        // The connect Task runs off-thread and will call scheduleReconnect
        // once the tokenProvider throws. Stopping immediately cancels the
        // reconnect schedule and forces .stopped regardless of whether the
        // Task has run yet.
        transport.stop()
        #expect(transport.state == .stopped)

        // Give the detached Task a beat to run the catch block; stop() must
        // still have the final word — the transport must not spontaneously
        // flip back to .starting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.state == .stopped)

        // And no sends slip through after the stop.
        #expect(throws: TransportError.notStarted) {
            try transport.send(data: Data("late".utf8), to: makeWSPeerID(0x44))
        }
    }

    // MARK: Lifecycle idempotency

    @Test("start → stop → start cycle is safe and does not leak state")
    func restartCycleIsSafe() async {
        let transport = makeWebSocketTransport()
        let delegate = MockTransportDelegate()
        transport.delegate = delegate

        transport.start()
        transport.stop()
        transport.start()
        transport.stop()

        #expect(transport.state == .stopped)
        // At minimum, we should have seen .starting and .stopped transitions.
        #expect(delegate.stateChanges.contains(.starting))
        #expect(delegate.stateChanges.contains(.stopped))
    }
}

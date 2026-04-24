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

    @Test("Foreground + path-change + ping reconnect triggers coalesce into one connect attempt")
    func concurrentReconnectTriggersCoalesce() async throws {
        actor TokenCounter {
            private(set) var count = 0

            func increment() {
                count += 1
            }
        }

        let counter = TokenCounter()
        let transport = makeWebSocketTransport(
            tokenProvider: {
                await counter.increment()
                return "test-token"
            }
        )
        let delegate = MockTransportDelegate()
        transport.delegate = delegate

        await withTaskGroup(of: Void.self) { group in
            group.addTask { transport.__testing_triggerForegroundReconnect() }
            group.addTask { transport.__testing_triggerPathReconnect() }
            group.addTask { transport.__testing_triggerPingReconnect() }
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(await counter.count == 1, "only one reconnect attempt should fetch a token")
        let startingCount = delegate.stateChanges.filter { $0 == .starting }.count
        #expect(startingCount == 1, "coalesced reconnect should emit one .starting transition, saw \(startingCount)")

        transport.stop()
    }

    // MARK: HEY1304 — reconnect while already connected must not strand state

    /// Regression for HEY1304. The original symptom was the iOS foreground
    /// handler logging `Foreground: relay not running (state=starting)` ~9
    /// minutes after the relay had reached `.running`, then self-healing via a
    /// reconnect.
    ///
    /// The cascade:
    /// 1. WebSocketTransport reached `.running`, `isConnected = true`.
    /// 2. A concurrent caller (path monitor, scenePhase observer, ...) saw a
    ///    stale `state` read and triggered `scheduleReconnect` →
    ///    `queue.asyncAfter` → `connect()` → `openWebSocket(using:)`.
    /// 3. `openWebSocket` cancelled the live task but did *not* reset
    ///    `isConnected`. The old task's `didClose`/`didComplete` callbacks were
    ///    dropped by the `isCurrentWebSocketTask` guard, so `isConnected`
    ///    stayed `true` forever.
    /// 4. When the new task handshook, `handleConnectionEstablished`
    ///    short-circuited on `!isConnected` and `state` never transitioned
    ///    back to `.running`.
    ///
    /// After the fix `openWebSocket` tears down the bookkeeping synchronously
    /// so the next `handleConnectionEstablished` cleanly drives state back to
    /// `.running`.
    @Test("Reconnect while already connected resets isConnected so the next handshake reaches .running")
    func reconnectWhileConnectedLeavesStateRecoverable() {
        let transport = makeWebSocketTransport()
        let delegate = MockTransportDelegate()
        transport.delegate = delegate

        // Drive the state machine through direct test hooks rather than
        // start() — start() spawns an async tokenProvider Task whose
        // URLSession activity would race with the invariants we want to
        // observe synchronously.
        transport.__testing_simulateRelayConnected()
        #expect(transport.state == .running)
        #expect(!transport.connectedPeers.isEmpty, "relay peer should be reported once connected")

        // Simulate scheduleReconnect's state transition firing because some
        // other caller saw a stale state read. State flips to .starting — the
        // exact fingerprint of the HEY1304 log line.
        transport.__testing_markReconnecting()
        #expect(transport.state == .starting)

        // Simulate the reconnect path calling openWebSocket. Before the fix
        // this left isConnected=true and no amount of subsequent handshakes
        // would set state back to .running. After the fix the teardown is
        // atomic: connectedPeers reports empty, signalling isConnected was
        // reset.
        transport.__testing_openWebSocket()
        #expect(
            transport.connectedPeers.isEmpty,
            "openWebSocket must clear isConnected when replacing a live task (HEY1304)"
        )

        // Drive the new task's handshake to completion. This must flip state
        // back to `.running`; if the `!isConnected` guard short-circuits here,
        // the regression is back.
        transport.__testing_simulateRelayConnected()
        #expect(
            transport.state == .running,
            "handleConnectionEstablished must restore .running after a reconnect — regression for HEY1304"
        )
        #expect(
            !transport.connectedPeers.isEmpty,
            "relay peer must be re-reported after the reconnect handshake"
        )

        // Delegate should have observed the full .running → .starting → .running
        // arc on the reconnect. Before the fix only the initial .running fires
        // and the reconnect gets stuck in .starting.
        let transitions = delegate.stateChanges
        let runningCount = transitions.filter { $0 == .running }.count
        #expect(
            runningCount >= 2,
            "delegate must observe .running on both the initial connect and the reconnect, saw \(runningCount) in \(transitions)"
        )

        transport.stop()
    }

    /// `state` is read from the main thread (foreground observer, UI) and
    /// written from URLSession's delegate queue, the path-monitor queue, and
    /// `connect()`'s Task. Without a lock-protected backing store the reader
    /// could observe a stale `.starting` long after the writer had transitioned
    /// to `.running` — which is exactly the HEY1304 fingerprint. This test
    /// exercises the read path under contention to surface data-race issues
    /// via TSan.
    @Test("Concurrent state reads during repeated transitions never observe torn values")
    func stateReadsUnderConcurrentTransitionsAreSafe() async {
        let transport = makeWebSocketTransport()
        transport.start()

        await withTaskGroup(of: Void.self) { group in
            // Writers: flip state between .running and .starting via the test
            // hooks. Each transition takes the lock, so readers should only
            // ever see one of the legal values.
            group.addTask {
                for _ in 0 ..< 200 {
                    transport.__testing_simulateRelayConnected()
                    transport.__testing_openWebSocket()
                }
            }

            // Readers: hammer the `state` getter from multiple threads.
            for _ in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 500 {
                        let s = transport.state
                        // Sanity: any of the declared cases is acceptable,
                        // but the read itself must not crash / be torn.
                        switch s {
                        case .idle, .starting, .running, .stopped, .unauthorized, .failed:
                            break
                        }
                    }
                }
            }
        }

        transport.stop()
        #expect(transport.state == .stopped)
    }
}

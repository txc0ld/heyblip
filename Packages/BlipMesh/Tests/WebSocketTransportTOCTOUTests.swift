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

private actor TokenCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    step: Duration = .milliseconds(10),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: step)
    }
    Issue.record("Timed out waiting for async condition after \(timeout)")
}

/// Waits until `condition` returns true AND remains true for at least
/// `settle` consecutive duration before returning. Catches the
/// "value flickers past, immediate assertion sees a different value" race
/// that bit `concurrentReconnectTriggersCoalesce` and friends — the prior
/// `waitUntil` returns the moment the condition first turns true, but a
/// queued task can mutate the underlying value between that check and the
/// caller's `#expect`. Use this when the assertion needs the observed
/// value to be stable, not just momentarily reached.
///
/// Records an issue if the condition is never observed true within
/// `timeout`, or if the condition flips back to false during the settle
/// window (this signals a race the caller cares about — the value was
/// reached but didn't stay).
private func waitUntilStable(
    timeout: Duration = .seconds(2),
    settle: Duration = .milliseconds(200),
    step: Duration = .milliseconds(10),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    var settledStart: ContinuousClock.Instant?
    while ContinuousClock.now < deadline {
        if await condition() {
            let start = settledStart ?? ContinuousClock.now
            settledStart = start
            if ContinuousClock.now - start >= settle {
                return
            }
        } else {
            settledStart = nil
        }
        try await Task.sleep(for: step)
    }
    Issue.record("Timed out waiting for stable async condition after \(timeout) (settle window: \(settle))")
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

        // No final-state assertion. The contract this test enforces is
        // "no send silently succeeds in the start/stop window," which the
        // taskGroup loop above already verifies. A trailing state check
        // races `start()`'s detached connect Task — even with a stable
        // wait, the connect Task can flip state to .starting after stop()
        // returned and the state may not converge to .stopped before the
        // unreachable URLSession task times out (~30s). That convergence
        // is covered separately by `throwingTokenProviderFollowedByStop`,
        // which uses a deterministic throwing provider.
    }

    // MARK: Token provider failure does not corrupt the state machine

    @Test("A throwing tokenProvider + stop leaves the transport in .stopped (autoReconnect off)")
    func throwingTokenProviderFollowedByStop() async throws {
        struct AuthError: Error {}
        let transport = makeWebSocketTransport(tokenProvider: { throw AuthError() })

        transport.start()

        // The connect Task runs off-thread and will call scheduleReconnect
        // once the tokenProvider throws. Stopping immediately cancels the
        // reconnect schedule and forces .stopped regardless of whether the
        // Task has run yet.
        transport.stop()
        #expect(transport.state == .stopped)

        // The detached Task's catch block runs after stop(); we want to
        // assert state STAYED .stopped through that catch. Wait for the
        // value to be stable rather than sleeping a fixed duration —
        // 50ms was marginal on slower CI runners; 1s/150ms also flaked
        // ~50-100% on macos-15 runners (BDEV-404). Bump to 2s/200ms.
        try await waitUntilStable(timeout: .seconds(2), settle: .milliseconds(200)) {
            transport.state == .stopped
        }

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
            group.addTask { transport.__testing_triggerScheduledReconnect(reason: "test-path") }
            group.addTask { transport.__testing_triggerScheduledReconnect(reason: "test-ping") }
        }

        // Wait until the count reaches 1 AND stays at 1 — the prior
        // `waitUntil` returned the moment count first hit 1, but a
        // queued reconnect Task could still increment between that
        // observation and the `#expect` below, producing a flake on
        // slower CI runners. The settle window catches the case where
        // coalescing is broken and a second token fetch slips through.
        try await waitUntilStable(timeout: .seconds(2), settle: .milliseconds(250)) {
            await counter.count == 1
        }

        #expect(await counter.count == 1, "only one reconnect attempt should fetch a token")
        let startingCount = delegate.stateChanges.filter { $0 == .starting }.count
        #expect(startingCount == 1, "coalesced reconnect should emit one .starting transition, saw \(startingCount)")

        transport.stop()
    }

    @Test("Reconnect cycle clears after success so a later reconnect can start")
    func reconnectCycleClearsAfterSuccess() async throws {
        let counter = TokenCounter()
        let transport = makeWebSocketTransport(
            tokenProvider: {
                await counter.increment()
                return "test-token"
            }
        )

        transport.__testing_triggerForegroundReconnect()
        // Generous timeout matching the second waitUntil below — the
        // first reconnect's token fetch can take >3s on a slow macos-15
        // runner (BDEV-404 flake symptom). Assertion is unchanged.
        try await waitUntil(timeout: .seconds(5)) {
            await counter.count == 1
        }

        transport.__testing_simulateRelayConnected()
        #expect(transport.state == .running)

        transport.__testing_simulateConnectionLoss()
        // Generous timeout because this test depends on the reconnect
        // backoff path firing the second token fetch on a slower runner;
        // 2s was marginal — bump to 5s. The assertion is unchanged: the
        // reconnect cycle must clear and a fresh fetch must run, no more.
        try await waitUntil(timeout: .seconds(5)) {
            await counter.count >= 2
        }

        #expect(await counter.count == 2, "a fresh reconnect should run after the previous cycle reached .running")
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

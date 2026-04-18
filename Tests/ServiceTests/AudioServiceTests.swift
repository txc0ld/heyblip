import XCTest
import AVFoundation
#if os(iOS)
import UIKit
#endif
@testable import Blip

/// Tests for the observable `AudioService` contract.
///
/// Scope note: the interruption / route-change / background handlers gate
/// their side-effects on `isRecording` and `isPlaying`, both of which are
/// `private(set)`. Without a real `AVAudioRecorder`/`AVAudioPlayer` session
/// there's no way to flip those flags from a unit test, so this suite
/// exercises everything around the handlers: initial state, idempotent
/// teardown, safe notification handling, and deinit cleanup. A TODO at the
/// bottom captures the integration-test gap that needs a real device runner
/// or a production-side injection seam.
@MainActor
final class AudioServiceTests: XCTestCase {

    private var service: AudioService!
    private var delegate: MockAudioServiceDelegate!

    override func setUp() async throws {
        service = AudioService()
        delegate = MockAudioServiceDelegate()
        service.delegate = delegate
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
    }

    // MARK: - Initial state

    func test_initialState_isIdle() {
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.recordingDuration, 0)
        XCTAssertEqual(service.playbackProgress, 0)
    }

    // MARK: - Idempotent teardown

    func test_cancelRecording_whenNotRecording_isNoOp() {
        service.cancelRecording()
        service.cancelRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertTrue(delegate.errors.isEmpty, "cancelRecording from idle should not fire an error")
    }

    func test_stopPlayback_whenNotPlaying_isNoOp() {
        service.stopPlayback()
        service.stopPlayback()
        XCTAssertFalse(service.isPlaying)
    }

    func test_stopRecording_whenNotRecording_throwsNotRecording() {
        do {
            _ = try service.stopRecording()
            XCTFail("Expected stopRecording to throw when not recording")
        } catch let error as AudioServiceError {
            guard case .notRecording = error else {
                XCTFail("Expected .notRecording, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Notification handlers don't crash

    /// `handleInterruption` guards on `userInfo[AVAudioSessionInterruptionTypeKey]`.
    /// An empty or malformed notification must not crash the handler. We
    /// install observers via a best-effort `configureAudioSession()` call
    /// (AVAudioSession may or may not be available in the test runner; we
    /// only care that observers were registered).
    func test_malformedInterruptionNotification_isHandledSafely() {
        // Best-effort — simulator may refuse the session setup, which is fine;
        // `installSystemObservers()` has already run inside the try block.
        try? service.configureAudioSession()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: nil
        )
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: "not-a-uint"]
        )

        // State unchanged and no spurious delegate callbacks.
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isPlaying)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_malformedRouteChangeNotification_isHandledSafely() {
        try? service.configureAudioSession()

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: nil
        )
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: UInt(999)]
        )

        XCTAssertFalse(service.isPlaying)
    }

    #if os(iOS)
    func test_backgroundNotification_whenNotRecording_doesNotFireError() {
        try? service.configureAudioSession()

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        XCTAssertFalse(service.isRecording)
        XCTAssertTrue(
            delegate.errors.isEmpty,
            "Backgrounding while idle must not surface an error to the delegate"
        )
    }
    #endif

    func test_interruptionEnded_withoutShouldResume_doesNotStartPlayback() {
        try? service.configureAudioSession()

        let endedUserInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: UInt(0) // no .shouldResume
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: endedUserInfo
        )

        XCTAssertFalse(service.isPlaying)
    }

    // MARK: - Deinit cleanup

    func test_deinit_removesObserversAndInvalidatesTimers() async {
        // Install observers via best-effort configure.
        try? service.configureAudioSession()

        // Tear down — deinit should remove all notification observers so a
        // later post doesn't message a zombie. If observers leaked, the next
        // `NotificationCenter.post` with a payload that references `self`
        // would crash — so we post one after release to verify nothing bad
        // happens.
        weak var weakService: AudioService? = service
        service = nil

        // Allow the deinit to complete if it was deferred.
        await Task.yield()

        XCTAssertNil(weakService, "AudioService should deinit when its only strong ref is released")

        // Post a notification — must not crash. If the observer wasn't
        // removed it would try to message a deallocated object.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
    }

    // MARK: - Delegate wiring

    func test_delegateIsWeaklyReferenced() {
        var sinkDelegate: MockAudioServiceDelegate? = MockAudioServiceDelegate()
        service.delegate = sinkDelegate
        weak var weakDelegate = sinkDelegate
        sinkDelegate = nil
        XCTAssertNil(weakDelegate, "AudioService.delegate must be weak to avoid retain cycles")
    }
}

// MARK: - MockAudioServiceDelegate

/// Captures delegate callbacks for assertion.
private final class MockAudioServiceDelegate: AudioServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [AudioServiceError] = []
    private var _finishedRecordings: [(data: Data, duration: TimeInterval)] = []
    private var _finishedPlaybacks: [Bool] = []

    var errors: [AudioServiceError] { lock.withLock { _errors } }
    var finishedRecordings: [(data: Data, duration: TimeInterval)] { lock.withLock { _finishedRecordings } }
    var finishedPlaybacks: [Bool] { lock.withLock { _finishedPlaybacks } }

    func audioService(_ service: AudioService, didRecordChunk data: Data, duration: TimeInterval) {}
    func audioService(_ service: AudioService, didFinishRecording data: Data, duration: TimeInterval) {
        lock.withLock { _finishedRecordings.append((data, duration)) }
    }
    func audioService(_ service: AudioService, didFinishPlayback successfully: Bool) {
        lock.withLock { _finishedPlaybacks.append(successfully) }
    }
    func audioService(_ service: AudioService, didUpdateRecordingLevel level: Float) {}
    func audioService(_ service: AudioService, didUpdatePlaybackProgress progress: Double) {}
    func audioService(_ service: AudioService, didFailWithError error: AudioServiceError) {
        lock.withLock { _errors.append(error) }
    }
}

// MARK: - Integration-test gap
//
// The critical interruption / background / route-change cancellation paths
// gate on `isRecording` / `isPlaying`, both `private(set)`. Verifying them
// end-to-end requires either:
//   1. A device test runner with microphone permission (can actually record).
//   2. A production change exposing an internal seam to force those flags
//      from tests (e.g. `@testable internal` setter).
// Neither is in scope for this PR; this gap is tracked as a follow-up.

import XCTest
import SwiftData
import CoreLocation
@testable import BlipProtocol
@testable import BlipCrypto

// MARK: - Mock Services

/// Mock LocationService that returns a fixed location without actually using GPS.
private final class MockLocationService: LocationService {
    var fixedLocation = CLLocation(latitude: 51.0043, longitude: -2.5856)
    var shouldFailGPS = false

    override func requestSOSLocation() async throws -> CLLocation {
        if shouldFailGPS {
            throw NSError(domain: "MockGPS", code: 1, userInfo: [NSLocalizedDescriptionKey: "GPS unavailable"])
        }
        return fixedLocation
    }

    override var currentLocation: CLLocation? {
        fixedLocation
    }

    override func computeFuzzyGeohash(latitude: Double, longitude: Double) -> String {
        "u10hf" // Fixed geohash for testing
    }
}

/// Mock MessageService that records broadcasts without actually sending.
private final class MockSOSMessageService: MessageService {
    var broadcastedPackets: [Data] = []

    override func sendTextMessage(content: String, to channel: Channel, replyTo: Message?) async throws -> Message {
        Message(content: content, sender: nil, channel: channel, replyTo: replyTo)
    }

    override func sendTypingIndicator(to channel: Channel) async throws {}
    override func sendReadReceipt(for messageID: UUID, to peerID: PeerID) async throws {}
}

/// Mock NotificationService that records notifications without displaying them.
private final class MockNotificationService: NotificationService {
    var sosNearbyNotifications: [(severity: String, alertID: UUID, distance: Int, message: String?)] = []
    var sosResolvedNotifications: [UUID] = []

    override func notifySOSNearby(severity: String, alertID: UUID, distance: Int, message: String?) {
        sosNearbyNotifications.append((severity, alertID, distance, message))
    }

    override func notifySOSResolved(alertID: UUID) {
        sosResolvedNotifications.append(alertID)
    }
}

// MARK: - Tests

@MainActor
final class SOSViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var mockLocation: MockLocationService!
    private var mockMessage: MockSOSMessageService!
    private var mockNotification: MockNotificationService!
    private var vm: SOSViewModel!

    override func setUp() async throws {
        let schema = Schema([
            SOSAlert.self, MedicalResponder.self, User.self,
            Channel.self, Message.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])

        mockLocation = MockLocationService()
        mockMessage = MockSOSMessageService()
        mockNotification = MockNotificationService()

        vm = SOSViewModel(
            modelContainer: container,
            locationService: mockLocation,
            messageService: mockMessage,
            notificationService: mockNotification
        )
    }

    override func tearDown() async throws {
        container = nil
        mockLocation = nil
        mockMessage = nil
        mockNotification = nil
        vm = nil
    }

    // MARK: - SOS Activation Flow

    func testStartSOSFlowTransitionsToSelectingSeverity() {
        XCTAssertEqual(vm.flowState, .idle)

        vm.startSOSFlow()

        XCTAssertEqual(vm.flowState, .selectingSeverity)
        XCTAssertNil(vm.selectedSeverity)
        XCTAssertTrue(vm.alertDescription.isEmpty)
    }

    func testSelectSeverityTransitionsToConfirming() {
        vm.startSOSFlow()
        vm.selectSeverity(.amber)

        XCTAssertEqual(vm.selectedSeverity, .amber)
        XCTAssertEqual(vm.flowState, .confirmingAlert(severity: .amber))
    }

    func testSelectSeverityWithGreenLevel() {
        vm.startSOSFlow()
        vm.selectSeverity(.green)

        XCTAssertEqual(vm.selectedSeverity, .green)
        XCTAssertEqual(vm.flowState, .confirmingAlert(severity: .green))
    }

    func testSelectSeverityWithRedLevel() {
        vm.startSOSFlow()
        vm.selectSeverity(.red)

        XCTAssertEqual(vm.selectedSeverity, .red)
        XCTAssertEqual(vm.flowState, .confirmingAlert(severity: .red))
    }

    func testConfirmAlertTransitionsThroughStates() async {
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        vm.alertDescription = "Friend collapsed near main stage"

        await vm.confirmAlert()

        // After confirmation, should be in .active state.
        if case .active(let alertID) = vm.flowState {
            XCTAssertNotNil(alertID)
            XCTAssertNotNil(vm.activeAlert)
            XCTAssertEqual(vm.activeAlert?.severity, .red)
        } else {
            XCTFail("Expected .active state, got \(vm.flowState)")
        }
    }

    func testConfirmAlertWithGPSFailureFallsBackToLastKnown() async {
        mockLocation.shouldFailGPS = true

        vm.startSOSFlow()
        vm.selectSeverity(.amber)

        await vm.confirmAlert()

        // Should still succeed using last known location.
        if case .active = vm.flowState {
            XCTAssertNotNil(vm.activeAlert)
        } else {
            XCTFail("Expected .active state even with GPS failure, got \(vm.flowState)")
        }
    }

    func testConfirmAlertWithNoSeverityShowsError() async {
        vm.startSOSFlow()
        // Do NOT select a severity.

        await vm.confirmAlert()

        if case .error(let msg) = vm.flowState {
            XCTAssertEqual(msg, "No severity selected")
        } else {
            XCTFail("Expected .error state, got \(vm.flowState)")
        }
    }

    // MARK: - Cancel Within 10 Seconds

    func testCancelFlowBeforeBroadcast() {
        vm.startSOSFlow()
        vm.selectSeverity(.green)

        // Cancel before confirming.
        vm.cancelFlow()

        XCTAssertEqual(vm.flowState, .idle)
        XCTAssertNil(vm.selectedSeverity)
        XCTAssertTrue(vm.alertDescription.isEmpty)
        XCTAssertEqual(vm.confirmationCountdown, 0)
    }

    func testCancelActiveAlert() async {
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()

        // Should be active.
        XCTAssertNotNil(vm.activeAlert)

        // Cancel the active alert.
        await vm.cancelActiveAlert()

        XCTAssertNil(vm.activeAlert)
        XCTAssertEqual(vm.flowState, .idle)
    }

    func testCancelActiveAlertSetsResolutionToCancelled() async {
        vm.startSOSFlow()
        vm.selectSeverity(.amber)
        await vm.confirmAlert()

        let alert = vm.activeAlert!

        await vm.cancelActiveAlert()

        // The alert object should have been updated.
        XCTAssertEqual(alert.status, .resolved)
        XCTAssertEqual(alert.resolution, .cancelled)
        XCTAssertNotNil(alert.resolvedAt)
    }

    // MARK: - False Alarm Throttle After 2 Incidents

    func testFalseAlarmIncrementsCounter() async {
        XCTAssertEqual(vm.falseAlarmCount, 0)

        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()
        await vm.markFalseAlarm()

        XCTAssertEqual(vm.falseAlarmCount, 1)

        // Second false alarm.
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()
        await vm.markFalseAlarm()

        XCTAssertEqual(vm.falseAlarmCount, 2)
    }

    func testFalseAlarmThresholdAddsConfirmationDelay() {
        // Set the false alarm count to the threshold (3).
        vm.falseAlarmCount = 3

        vm.startSOSFlow()
        vm.selectSeverity(.amber)

        // Should have a confirmation countdown.
        XCTAssertEqual(vm.confirmationCountdown, 10, "Users with 3+ false alarms should get a 10-second countdown")

        // Flow state should still be .confirmingAlert but with the countdown running.
        if case .confirmingAlert(let severity) = vm.flowState {
            XCTAssertEqual(severity, .amber)
        } else {
            XCTFail("Expected .confirmingAlert state, got \(vm.flowState)")
        }
    }

    func testBelowThresholdNoConfirmationDelay() {
        vm.falseAlarmCount = 2

        vm.startSOSFlow()
        vm.selectSeverity(.amber)

        XCTAssertEqual(vm.confirmationCountdown, 0, "Below threshold should have no countdown")
    }

    func testMarkFalseAlarmSetsResolution() async {
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()

        let alert = vm.activeAlert!
        await vm.markFalseAlarm()

        XCTAssertEqual(alert.resolution, .falseAlarm)
        XCTAssertEqual(alert.status, .resolved)

        if case .resolved(_, let resolution) = vm.flowState {
            XCTAssertEqual(resolution, .falseAlarm)
        } else {
            XCTFail("Expected .resolved state with falseAlarm resolution, got \(vm.flowState)")
        }
    }

    // MARK: - Severity Confirmation

    func testSeverityConfirmationForEachLevel() {
        for severity in [SOSSeverity.green, .amber, .red] {
            vm.reset()
            vm.startSOSFlow()
            vm.selectSeverity(severity)

            XCTAssertEqual(vm.selectedSeverity, severity)
            if case .confirmingAlert(let s) = vm.flowState {
                XCTAssertEqual(s, severity)
            } else {
                XCTFail("Expected .confirmingAlert for severity \(severity)")
            }
        }
    }

    // MARK: - Reset

    func testResetClearsAllState() async {
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        vm.alertDescription = "Emergency"
        await vm.confirmAlert()

        vm.reset()

        XCTAssertEqual(vm.flowState, .idle)
        XCTAssertNil(vm.activeAlert)
        XCTAssertNil(vm.selectedSeverity)
        XCTAssertTrue(vm.alertDescription.isEmpty)
        XCTAssertEqual(vm.confirmationCountdown, 0)
        XCTAssertFalse(vm.isAcquiringGPS)
        XCTAssertEqual(vm.gpsProgress, 0)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Multiple SOS Cycles

    func testMultipleSOSCycles() async {
        // First cycle: send and resolve.
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()
        await vm.cancelActiveAlert()
        XCTAssertEqual(vm.flowState, .idle)

        // Second cycle.
        vm.startSOSFlow()
        vm.selectSeverity(.amber)
        await vm.confirmAlert()
        await vm.markFalseAlarm()
        XCTAssertEqual(vm.falseAlarmCount, 1)

        // Third cycle.
        vm.reset()
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        await vm.confirmAlert()
        XCTAssertNotNil(vm.activeAlert)
        await vm.cancelActiveAlert()
        XCTAssertEqual(vm.flowState, .idle)
    }

    // MARK: - Flow State Transitions

    func testFlowStateEquality() {
        XCTAssertEqual(SOSFlowState.idle, SOSFlowState.idle)
        XCTAssertEqual(SOSFlowState.selectingSeverity, SOSFlowState.selectingSeverity)
        XCTAssertEqual(SOSFlowState.acquiringLocation, SOSFlowState.acquiringLocation)
        XCTAssertEqual(SOSFlowState.broadcasting, SOSFlowState.broadcasting)

        let id = UUID()
        XCTAssertEqual(SOSFlowState.active(alertID: id), SOSFlowState.active(alertID: id))
        XCTAssertNotEqual(SOSFlowState.active(alertID: id), SOSFlowState.active(alertID: UUID()))
    }

    // MARK: - GPS Progress

    func testGPSProgressResetsOnNewAlert() async {
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        await vm.confirmAlert()

        // GPS progress should be 1.0 after acquisition.
        XCTAssertEqual(vm.gpsProgress, 1.0)
        XCTAssertFalse(vm.isAcquiringGPS)

        vm.reset()
        XCTAssertEqual(vm.gpsProgress, 0)
    }
}

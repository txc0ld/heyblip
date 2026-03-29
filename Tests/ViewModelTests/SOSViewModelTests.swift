import XCTest
import SwiftData
import CoreLocation
@testable import Blip

// MARK: - Tests

/// Tests for SOSViewModel state machine, severity selection, false alarm tracking, and reset logic.
///
/// Note: Tests that require GPS acquisition (confirmAlert success path) are limited because
/// LocationService is a final class that wraps CLLocationManager, which is unavailable in the
/// test environment. The confirm-and-activate tests validate the error/fallback paths instead.
@MainActor
final class SOSViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var locationService: LocationService!
    private var messageService: MessageService!
    private var notificationService: NotificationService!
    private var vm: SOSViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        locationService = LocationService()
        messageService = MessageService(modelContainer: container)
        notificationService = NotificationService()

        vm = SOSViewModel(
            modelContainer: container,
            locationService: locationService,
            messageService: messageService,
            notificationService: notificationService
        )
    }

    override func tearDown() async throws {
        container = nil
        locationService = nil
        messageService = nil
        notificationService = nil
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

    func testConfirmAlertWithNoLocationFallsToError() async {
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        vm.alertDescription = "Friend collapsed near main stage"

        await vm.confirmAlert()

        // Without GPS or a cached location, the VM should enter the error state.
        if case .error(let msg) = vm.flowState {
            XCTAssertEqual(msg, "Unable to determine location")
        } else {
            XCTFail("Expected .error state when no location available, got \(vm.flowState)")
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

    // MARK: - Cancel Before Broadcast

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

    // MARK: - Cancel Active Alert (requires pre-populated alert)

    func testCancelActiveAlertSetsResolution() async {
        // Manually create an active alert in the container and assign it to the VM.
        let context = ModelContext(container)
        let alert = SOSAlert(
            severity: .amber,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert)
        try? context.save()

        vm.activeAlert = alert
        vm.flowState = .active(alertID: alert.id)

        await vm.cancelActiveAlert()

        XCTAssertNil(vm.activeAlert)
        XCTAssertEqual(vm.flowState, .idle)
        XCTAssertEqual(alert.status, .resolved)
        XCTAssertEqual(alert.resolution, .cancelled)
        XCTAssertNotNil(alert.resolvedAt)
    }

    // MARK: - False Alarm Tracking

    func testFalseAlarmIncrementsCounter() async {
        XCTAssertEqual(vm.falseAlarmCount, 0)

        // Create first alert and mark as false alarm.
        let context = ModelContext(container)
        let alert1 = SOSAlert(
            severity: .green,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert1)
        try? context.save()

        vm.activeAlert = alert1
        vm.flowState = .active(alertID: alert1.id)
        await vm.markFalseAlarm()

        XCTAssertEqual(vm.falseAlarmCount, 1)

        // Second false alarm.
        let alert2 = SOSAlert(
            severity: .green,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert2)
        try? context.save()

        vm.activeAlert = alert2
        vm.flowState = .active(alertID: alert2.id)
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
        let context = ModelContext(container)
        let alert = SOSAlert(
            severity: .green,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert)
        try? context.save()

        vm.activeAlert = alert
        vm.flowState = .active(alertID: alert.id)

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

    func testResetClearsAllState() {
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        vm.alertDescription = "Emergency"

        // Simulate some state.
        vm.falseAlarmCount = 2

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

    func testMultipleSOSCyclesWithCancellation() async {
        // First cycle: start, select, cancel before confirm.
        vm.startSOSFlow()
        vm.selectSeverity(.green)
        vm.cancelFlow()
        XCTAssertEqual(vm.flowState, .idle)

        // Second cycle: start, select, cancel flow again.
        vm.startSOSFlow()
        vm.selectSeverity(.amber)
        vm.cancelFlow()
        XCTAssertEqual(vm.flowState, .idle)

        // Third cycle: start, select, confirm (will error due to no GPS), reset.
        vm.startSOSFlow()
        vm.selectSeverity(.red)
        await vm.confirmAlert()
        // Regardless of outcome, reset should bring us back to idle.
        vm.reset()
        XCTAssertEqual(vm.flowState, .idle)
    }

    func testMultipleCancellationsOfActiveAlerts() async {
        let context = ModelContext(container)

        // First cycle: create alert, cancel it.
        let alert1 = SOSAlert(
            severity: .green,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert1)
        try? context.save()

        vm.activeAlert = alert1
        vm.flowState = .active(alertID: alert1.id)
        await vm.cancelActiveAlert()
        XCTAssertEqual(vm.flowState, .idle)
        XCTAssertNil(vm.activeAlert)

        // Second cycle: create alert, mark false alarm.
        let alert2 = SOSAlert(
            severity: .amber,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert2)
        try? context.save()

        vm.activeAlert = alert2
        vm.flowState = .active(alertID: alert2.id)
        await vm.markFalseAlarm()
        XCTAssertEqual(vm.falseAlarmCount, 1)
        XCTAssertNil(vm.activeAlert)
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

    func testGPSProgressResetsOnReset() {
        // Manually set some GPS state.
        vm.gpsProgress = 0.75
        vm.isAcquiringGPS = true

        vm.reset()

        XCTAssertEqual(vm.gpsProgress, 0)
        XCTAssertFalse(vm.isAcquiringGPS)
    }

    // MARK: - Alert Description

    func testAlertDescriptionIsIncludedInFlow() {
        vm.startSOSFlow()
        vm.alertDescription = "Someone fainted near the water station"
        vm.selectSeverity(.amber)

        XCTAssertEqual(vm.alertDescription, "Someone fainted near the water station")
        XCTAssertEqual(vm.selectedSeverity, .amber)
    }

    func testCancelFlowClearsAlertDescription() {
        vm.startSOSFlow()
        vm.alertDescription = "Test description"
        vm.selectSeverity(.green)

        vm.cancelFlow()

        XCTAssertTrue(vm.alertDescription.isEmpty)
    }
}

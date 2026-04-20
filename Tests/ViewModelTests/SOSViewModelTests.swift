import XCTest
import SwiftData
import CoreLocation
@testable import Blip
@testable import BlipCrypto
import BlipProtocol
import BlipMesh

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
    private let testPeerID = PeerID(bytes: Data(repeating: 0x01, count: PeerID.length))!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        locationService = LocationService()
        messageService = MessageService(modelContainer: container)
        notificationService = NotificationService()

        vm = SOSViewModel(
            modelContainer: container,
            bleService: BLEService(localPeerID: testPeerID),
            locationService: locationService,
            messageService: messageService,
            notificationService: notificationService
        )
    }

    override func tearDown() async throws {
        try? KeyManager.shared.deleteIdentity()
        container = nil
        locationService = nil
        messageService = nil
        notificationService = nil
        vm = nil
    }

    private func waitFor(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !condition() && ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func captureBroadcastPacket(
        trigger: @escaping @MainActor () async -> Void
    ) async throws -> Packet {
        try? KeyManager.shared.deleteIdentity()
        let identity = try KeyManager.shared.generateIdentity()
        try KeyManager.shared.storeIdentity(identity)

        let expectation = expectation(description: "broadcast packet")
        var observer: NSObjectProtocol?
        var capturedPacket: Packet?

        observer = NotificationCenter.default.addObserver(
            forName: .shouldBroadcastPacket,
            object: nil,
            queue: .main
        ) { notification in
            guard let data = notification.userInfo?["data"] as? Data else { return }
            capturedPacket = try? PacketSerializer.decode(data)
            expectation.fulfill()
        }

        await trigger()
        await fulfillment(of: [expectation], timeout: 1.0)

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        return try XCTUnwrap(capturedPacket)
    }

    private func decodeResolvePayload(_ payload: Data) -> (UUID, UInt8?)? {
        if let separatorIndex = payload.firstIndex(of: 0x00) {
            let uuidData = payload[..<separatorIndex]
            guard let uuidString = String(data: Data(uuidData), encoding: .utf8),
                  let alertID = UUID(uuidString: uuidString) else {
                return nil
            }

            let byteIndex = payload.index(after: separatorIndex)
            let resolutionByte = byteIndex < payload.endIndex ? payload[byteIndex] : nil
            return (alertID, resolutionByte)
        }

        guard let uuidString = String(data: payload, encoding: .utf8),
              let alertID = UUID(uuidString: uuidString) else {
            return nil
        }

        return (alertID, nil)
    }

    // MARK: - Init Hydration

    func testInitLoadsResponderStatusAndVisibleAlerts() async throws {
        let context = ModelContext(container)
        let responder = MedicalResponder(
            accessCodeHash: "hash",
            callsign: "Medic-1",
            isOnDuty: true
        )
        let alert = SOSAlert(
            severity: .red,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            message: "Need help",
            status: .active,
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(responder)
        context.insert(alert)
        try context.save()

        let hydratedViewModel = SOSViewModel(
            modelContainer: container,
            bleService: BLEService(localPeerID: testPeerID),
            locationService: locationService,
            messageService: messageService,
            notificationService: notificationService
        )

        await waitFor {
            hydratedViewModel.isMedicalResponder &&
            hydratedViewModel.responderCallsign == "Medic-1" &&
            hydratedViewModel.isOnDuty &&
            hydratedViewModel.visibleAlerts.contains(where: { $0.id == alert.id })
        }

        XCTAssertTrue(hydratedViewModel.isMedicalResponder)
        XCTAssertEqual(hydratedViewModel.responderCallsign, "Medic-1")
        XCTAssertTrue(hydratedViewModel.isOnDuty)
        XCTAssertEqual(hydratedViewModel.visibleAlerts.count, 1)
        XCTAssertEqual(hydratedViewModel.visibleAlerts.first?.id, alert.id)
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

    func testCancelActiveAlertBroadcastsCancelledResolutionByte() async throws {
        let context = ModelContext(container)
        let alert = SOSAlert(
            severity: .amber,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert)
        try context.save()

        vm.activeAlert = alert
        vm.flowState = .active(alertID: alert.id)

        let packet = try await captureBroadcastPacket {
            await self.vm.cancelActiveAlert()
        }

        XCTAssertEqual(packet.type, .sosResolve)
        let decoded = try XCTUnwrap(decodeResolvePayload(packet.payload))
        XCTAssertEqual(decoded.0, alert.id)
        XCTAssertEqual(decoded.1, 0x04)
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

    func testMarkFalseAlarmBroadcastsFalseAlarmResolutionByte() async throws {
        let context = ModelContext(container)
        let alert = SOSAlert(
            severity: .green,
            preciseLocation: GeoPoint(latitude: 51.0, longitude: -2.5),
            fuzzyLocation: "u10hf",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        context.insert(alert)
        try context.save()

        vm.activeAlert = alert
        vm.flowState = .active(alertID: alert.id)

        let packet = try await captureBroadcastPacket {
            await self.vm.markFalseAlarm()
        }

        XCTAssertEqual(packet.type, .sosResolve)
        let decoded = try XCTUnwrap(decodeResolvePayload(packet.payload))
        XCTAssertEqual(decoded.0, alert.id)
        XCTAssertEqual(decoded.1, 0x03)
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

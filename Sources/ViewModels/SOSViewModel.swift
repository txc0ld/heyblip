import Foundation
import SwiftData
import CoreLocation
import BlipProtocol
import BlipMesh
import BlipCrypto
import os.log

// MARK: - SOS Flow State

/// States of the SOS alert flow.
enum SOSFlowState: Sendable, Equatable {
    /// No active SOS flow.
    case idle
    /// User is selecting severity.
    case selectingSeverity
    /// Awaiting user confirmation before broadcasting.
    case confirmingAlert(severity: SOSSeverity)
    /// Acquiring precise GPS location.
    case acquiringLocation
    /// Broadcasting the alert.
    case broadcasting
    /// Alert is active and waiting for responder.
    case active(alertID: UUID)
    /// A responder has accepted the alert.
    case responderAccepted(alertID: UUID, responderName: String)
    /// Alert has been resolved.
    case resolved(alertID: UUID, resolution: SOSResolution)
    /// Error occurred.
    case error(String)
}

// MARK: - SOS View Model

/// Manages the SOS alert flow: severity selection, confirmation, GPS acquisition, broadcast,
/// and medical responder dashboard.
///
/// SOS Flow:
/// 1. User taps SOS button -> severity selection screen
/// 2. User selects severity (green/amber/red) -> confirmation dialog
/// 3. On confirm -> acquire precise GPS -> broadcast sosAlert packet
/// 4. Wait for sosAccept from medical responder
/// 5. On accept -> share precise location with responder
/// 6. On resolve -> close alert
///
/// Medical Responder Dashboard:
/// - View active SOS alerts on map
/// - Accept an alert to claim it
/// - Navigate to patient location
/// - Resolve with outcome (treated on site, transported, false alarm, cancelled)
///
/// False alarm tracking:
/// - Users who trigger false alarms get a counter incremented
/// - After 3 false alarms, a confirmation delay is added
@MainActor
@Observable
final class SOSViewModel {

    // MARK: - Published State

    /// Current SOS flow state.
    var flowState: SOSFlowState = .idle

    /// The active SOS alert, if any.
    var activeAlert: SOSAlert?

    /// All active SOS alerts visible on the mesh (for responders).
    var visibleAlerts: [SOSAlertInfo] = []

    /// The user's false alarm count.
    var falseAlarmCount: Int = 0

    /// Whether this user is a registered medical responder.
    var isMedicalResponder = false

    /// The responder's callsign (if medical responder).
    var responderCallsign: String?

    /// Whether the responder is on duty.
    var isOnDuty = false

    /// Alert the responder has accepted.
    var acceptedAlert: SOSAlert?

    /// Error message, if any.
    var errorMessage: String?

    /// Selected severity (for the selection screen).
    var selectedSeverity: SOSSeverity?

    /// Optional description for the alert.
    var alertDescription: String = ""

    /// Whether GPS acquisition is in progress.
    var isAcquiringGPS = false

    /// GPS acquisition progress (seconds elapsed / max wait time).
    var gpsProgress: Double = 0

    /// Countdown seconds remaining for false-alarm-delayed users.
    var confirmationCountdown: Int = 0

    // MARK: - Supporting Types

    struct SOSAlertInfo: Identifiable, Sendable {
        let id: UUID
        let severity: SOSSeverity
        let fuzzyLocation: String
        let latitude: Double
        let longitude: Double
        let message: String?
        let description: String?
        let reporterName: String?
        let createdAt: Date
        let status: SOSStatus
        let distance: CLLocationDistance?
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let locationService: LocationService
    private let messageService: MessageService
    private let notificationService: NotificationService
    private let logger = Logger(subsystem: "com.blip", category: "SOSViewModel")
    @ObservationIgnored nonisolated(unsafe) private var sosObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var countdownTimer: Timer?

    // MARK: - Constants

    /// GPS acquisition timeout (seconds).
    private static let gpsTimeout: TimeInterval = 10.0

    /// False alarm threshold before adding confirmation delay.
    private static let falseAlarmThreshold = 3

    /// Confirmation delay for users with many false alarms (seconds).
    private static let falseAlarmDelay = 10

    /// SOS alert expiration (24 hours + event duration).
    private static let alertExpiration: TimeInterval = 86_400

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        locationService: LocationService,
        messageService: MessageService,
        notificationService: NotificationService
    ) {
        self.modelContainer = modelContainer
        self.locationService = locationService
        self.messageService = messageService
        self.notificationService = notificationService

        setupSOSReceiver()
    }

    deinit {
        if let obs = sosObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - SOS Flow

    /// Start the SOS flow (opens severity selection).
    func startSOSFlow() {
        flowState = .selectingSeverity
        selectedSeverity = nil
        alertDescription = ""
    }

    /// Select a severity level and move to confirmation.
    func selectSeverity(_ severity: SOSSeverity) {
        selectedSeverity = severity

        // Check false alarm delay
        if falseAlarmCount >= Self.falseAlarmThreshold {
            confirmationCountdown = Self.falseAlarmDelay
            startConfirmationCountdown(severity: severity)
        } else {
            flowState = .confirmingAlert(severity: severity)
        }
    }

    /// Confirm and trigger the SOS alert.
    func confirmAlert() async {
        guard let severity = selectedSeverity else {
            flowState = .error("No severity selected")
            return
        }

        // Acquire GPS
        flowState = .acquiringLocation
        isAcquiringGPS = true
        gpsProgress = 0

        let location: CLLocation
        // Start a progress timer — defer ensures cleanup on ALL exit paths
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.gpsProgress = min(1.0, self.gpsProgress + (0.5 / Self.gpsTimeout))
            }
        }
        defer { progressTimer.invalidate() }

        do {
            location = try await locationService.requestSOSLocation()
            gpsProgress = 1.0
        } catch {
            isAcquiringGPS = false
            // Fall back to last known location
            if let lastKnown = locationService.currentLocation {
                location = lastKnown
            } else {
                flowState = .error("Unable to determine location")
                return
            }
        }

        isAcquiringGPS = false

        // Create fuzzy location (geohash precision 5 = ~1.2km)
        let fuzzyGeohash = locationService.computeFuzzyGeohash(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )

        // Create alert
        flowState = .broadcasting

        let context = ModelContext(modelContainer)
        let alert = SOSAlert(
            severity: severity,
            preciseLocation: GeoPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            fuzzyLocation: fuzzyGeohash,
            message: alertDescription.isEmpty ? nil : alertDescription,
            alertDescription: alertDescription.isEmpty ? nil : alertDescription,
            falseAlarmCount: falseAlarmCount,
            expiresAt: Date().addingTimeInterval(Self.alertExpiration)
        )

        context.insert(alert)
        do {
            try context.save()
        } catch {
            flowState = .error("Failed to save alert: \(error.localizedDescription)")
            return
        }

        activeAlert = alert

        // Broadcast SOS packet
        await broadcastSOSAlert(alert, severity: severity, fuzzyGeohash: fuzzyGeohash)
        await broadcastSOSPreciseLocation(alert)

        flowState = .active(alertID: alert.id)
    }

    /// Cancel the SOS flow before broadcasting.
    func cancelFlow() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        flowState = .idle
        selectedSeverity = nil
        alertDescription = ""
        confirmationCountdown = 0
    }

    /// Cancel an active alert (user false alarm).
    func cancelActiveAlert() async {
        guard let alert = activeAlert else { return }

        let context = ModelContext(modelContainer)
        alert.status = .resolved
        alert.resolution = .cancelled
        alert.resolvedAt = Date()

        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }

        // Broadcast resolution
        await broadcastSOSResolve(alertID: alert.id)

        activeAlert = nil
        flowState = .idle
    }

    /// Mark an active alert as a false alarm (increments counter).
    func markFalseAlarm() async {
        guard let alert = activeAlert else { return }

        let context = ModelContext(modelContainer)
        alert.status = .resolved
        alert.resolution = .falseAlarm
        alert.resolvedAt = Date()
        alert.falseAlarmCount += 1

        falseAlarmCount += 1

        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }

        await broadcastSOSResolve(alertID: alert.id)

        activeAlert = nil
        flowState = .resolved(alertID: alert.id, resolution: .falseAlarm)
    }

    // MARK: - Medical Responder Actions

    /// Load the user's medical responder status.
    func loadResponderStatus() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MedicalResponder>()

        let responders: [MedicalResponder]
        do {
            responders = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch medical responders: \(error.localizedDescription)")
            return
        }

        if let responder = responders.first {
            isMedicalResponder = true
            responderCallsign = responder.callsign
            isOnDuty = responder.isOnDuty
        }
    }

    /// Toggle responder on-duty status.
    func toggleOnDuty() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MedicalResponder>()

        let responder: MedicalResponder
        do {
            guard let fetched = try context.fetch(descriptor).first else { return }
            responder = fetched
        } catch {
            logger.error("Failed to fetch medical responder: \(error.localizedDescription)")
            return
        }

        responder.isOnDuty.toggle()
        isOnDuty = responder.isOnDuty

        do {
            try context.save()
        } catch {
            logger.error("Failed to save responder on-duty status: \(error.localizedDescription)")
        }
    }

    /// Accept an SOS alert as a medical responder.
    func acceptAlert(_ alertInfo: SOSAlertInfo) async {
        let context = ModelContext(modelContainer)

        let alert: SOSAlert
        do {
            guard let fetched = try context.fetch(FetchDescriptor<SOSAlert>())
                .first(where: { $0.id == alertInfo.id }) else {
                errorMessage = "Alert not found"
                return
            }
            alert = fetched
        } catch {
            logger.error("Failed to fetch SOS alert: \(error.localizedDescription)")
            errorMessage = "Alert not found"
            return
        }

        let responderDescriptor = FetchDescriptor<MedicalResponder>()
        let responder: MedicalResponder
        do {
            guard let fetched = try context.fetch(responderDescriptor).first else {
                errorMessage = "Responder profile not found"
                return
            }
            responder = fetched
        } catch {
            logger.error("Failed to fetch medical responder: \(error.localizedDescription)")
            errorMessage = "Responder profile not found"
            return
        }

        alert.status = .accepted
        alert.acceptedBy = responder
        alert.acceptedAt = Date()
        responder.activeAlert = alert
        responder.responseCount += 1

        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        acceptedAlert = alert

        // Broadcast acceptance
        await broadcastSOSAccept(alertID: alert.id)
    }

    /// Resolve an accepted alert with an outcome.
    func resolveAlert(resolution: SOSResolution) async {
        guard let alert = acceptedAlert else { return }

        let context = ModelContext(modelContainer)
        alert.status = .resolved
        alert.resolution = resolution
        alert.resolvedAt = Date()

        let responderDescriptor = FetchDescriptor<MedicalResponder>()
        do {
            if let responder = try context.fetch(responderDescriptor).first {
                responder.activeAlert = nil
                // Update average response time
                if let acceptedAt = alert.acceptedAt {
                    let responseTime = Date().timeIntervalSince(acceptedAt)
                    let count = Double(responder.responseCount)
                    responder.avgResponseTime = ((responder.avgResponseTime * (count - 1)) + responseTime) / count
                }
            }
        } catch {
            logger.error("Failed to fetch medical responder for resolution: \(error.localizedDescription)")
        }

        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }

        await broadcastSOSResolve(alertID: alert.id)

        notificationService.notifySOSResolved(alertID: alert.id)

        acceptedAlert = nil
        flowState = .resolved(alertID: alert.id, resolution: resolution)
    }

    /// Refresh visible SOS alerts from SwiftData.
    func refreshVisibleAlerts() async {
        let context = ModelContext(modelContainer)

        let alerts: [SOSAlert]
        do {
            alerts = try context.fetch(FetchDescriptor<SOSAlert>())
                .filter { $0.statusRaw == "active" || $0.statusRaw == "accepted" }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            logger.error("Failed to fetch visible SOS alerts: \(error.localizedDescription)")
            return
        }

        let userLocation = locationService.currentLocation

        visibleAlerts = alerts.map { alert in
            let distance: CLLocationDistance?
            if let userLoc = userLocation {
                let alertLoc = CLLocation(
                    latitude: alert.preciseLocationLatitude,
                    longitude: alert.preciseLocationLongitude
                )
                distance = userLoc.distance(from: alertLoc)
            } else {
                distance = nil
            }

            return SOSAlertInfo(
                id: alert.id,
                severity: alert.severity,
                fuzzyLocation: alert.fuzzyLocation,
                latitude: alert.preciseLocationLatitude,
                longitude: alert.preciseLocationLongitude,
                message: alert.message,
                description: alert.alertDescription,
                reporterName: alert.reporter?.resolvedDisplayName,
                createdAt: alert.createdAt,
                status: alert.status,
                distance: distance
            )
        }.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    // MARK: - Private: Broadcasting

    private func broadcastSOSAlert(_ alert: SOSAlert, severity: SOSSeverity, fuzzyGeohash: String) async {
        let identity: Identity
        do {
            guard let loaded = try KeyManager.shared.loadIdentity() else {
                logger.error("No identity found for SOS broadcast")
                return
            }
            identity = loaded
        } catch {
            logger.error("Failed to load identity for SOS alert broadcast: \(error.localizedDescription)")
            return
        }

        // Build payload: severity (1 byte) + fuzzy geohash + optional message
        var payload = Data()
        let severityByte: UInt8
        switch severity {
        case .green: severityByte = 0x01
        case .amber: severityByte = 0x02
        case .red: severityByte = 0x03
        }
        payload.append(severityByte)
        payload.append(fuzzyGeohash.data(using: .utf8) ?? Data())
        payload.append(0x00) // separator
        if let desc = alert.alertDescription {
            payload.append(desc.data(using: .utf8) ?? Data())
        }

        let packet = Packet(
            type: .sosAlert,
            ttl: 7, // Maximum TTL for SOS
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: identity.peerID,
            payload: payload
        )

        let wireData: Data
        do {
            wireData = try PacketSerializer.encode(packet)
        } catch {
            logger.error("Failed to encode SOS alert packet: \(error.localizedDescription)")
            return
        }
        // Transport handles the actual send via NotificationCenter
        NotificationCenter.default.post(
            name: .shouldBroadcastPacket,
            object: nil,
            userInfo: ["data": wireData, "priority": "sos"]
        )
    }

    private func broadcastSOSAccept(alertID: UUID) async {
        let identity: Identity
        do {
            guard let loaded = try KeyManager.shared.loadIdentity() else {
                logger.error("No identity found for SOS broadcast")
                return
            }
            identity = loaded
        } catch {
            logger.error("Failed to load identity for SOS accept broadcast: \(error.localizedDescription)")
            return
        }

        var payload = Data()
        payload.append(alertID.uuidString.data(using: .utf8) ?? Data())

        let packet = Packet(
            type: .sosAccept,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: identity.peerID,
            payload: payload
        )

        do {
            let data = try PacketSerializer.encode(packet)
            NotificationCenter.default.post(
                name: .shouldBroadcastPacket,
                object: nil,
                userInfo: ["data": data, "priority": "sos"]
            )
        } catch {
            logger.error("Failed to encode SOS accept packet: \(error.localizedDescription)")
            return
        }
    }

    private func broadcastSOSPreciseLocation(_ alert: SOSAlert) async {
        let identity: Identity
        do {
            guard let loaded = try KeyManager.shared.loadIdentity() else {
                logger.error("No identity found for SOS precise location broadcast")
                return
            }
            identity = loaded
        } catch {
            logger.error("Failed to load identity for SOS precise location broadcast: \(error.localizedDescription)")
            return
        }

        var payload = Data()
        payload.append(alert.id.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)

        var latitudeBits = alert.preciseLocationLatitude.bitPattern.littleEndian
        withUnsafeBytes(of: &latitudeBits) { payload.append(contentsOf: $0) }

        var longitudeBits = alert.preciseLocationLongitude.bitPattern.littleEndian
        withUnsafeBytes(of: &longitudeBits) { payload.append(contentsOf: $0) }

        let packet = Packet(
            type: .sosPreciseLocation,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: identity.peerID,
            payload: payload
        )

        do {
            let data = try PacketSerializer.encode(packet)
            NotificationCenter.default.post(
                name: .shouldBroadcastPacket,
                object: nil,
                userInfo: ["data": data, "priority": "sos"]
            )
        } catch {
            logger.error("Failed to encode SOS precise location packet: \(error.localizedDescription)")
        }
    }

    private func broadcastSOSResolve(alertID: UUID) async {
        let identity: Identity
        do {
            guard let loaded = try KeyManager.shared.loadIdentity() else {
                logger.error("No identity found for SOS broadcast")
                return
            }
            identity = loaded
        } catch {
            logger.error("Failed to load identity for SOS resolve broadcast: \(error.localizedDescription)")
            return
        }

        var payload = Data()
        payload.append(alertID.uuidString.data(using: .utf8) ?? Data())

        let packet = Packet(
            type: .sosResolve,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: identity.peerID,
            payload: payload
        )

        do {
            let data = try PacketSerializer.encode(packet)
            NotificationCenter.default.post(
                name: .shouldBroadcastPacket,
                object: nil,
                userInfo: ["data": data, "priority": "sos"]
            )
        } catch {
            logger.error("Failed to encode SOS resolve packet: \(error.localizedDescription)")
            return
        }
    }

    // MARK: - Private: SOS Receiver

    private func setupSOSReceiver() {
        sosObservation = NotificationCenter.default.addObserver(
            forName: .didReceiveSOSPacket,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let packet = notification.userInfo?["packet"] as? Packet else { return }

            Task { @MainActor in
                await self?.handleReceivedSOSPacket(packet)
            }
        }
    }

    private func handleReceivedSOSPacket(_ packet: Packet) async {
        switch packet.type {
        case .sosAlert:
            await handleIncomingSOS(packet)
        case .sosAccept:
            await handleSOSAccepted(packet)
        case .sosPreciseLocation:
            await handleIncomingPreciseLocation(packet)
        case .sosResolve:
            await handleSOSResolved(packet)
        case .sosNearbyAssist:
            handleNearbyAssistRequest(packet)
        default:
            break
        }
    }

    private func handleIncomingSOS(_ packet: Packet) async {
        let payload = packet.payload
        guard !payload.isEmpty else { return }

        let severityByte = payload[payload.startIndex]
        let severity: SOSSeverity
        switch severityByte {
        case 0x01: severity = .green
        case 0x02: severity = .amber
        case 0x03: severity = .red
        default: severity = .amber
        }

        // Parse fuzzy location and message
        let remaining = payload.dropFirst()
        let parts = remaining.split(separator: 0x00, maxSplits: 1)
        let fuzzyGeohash = String(data: Data(parts.first ?? Data()), encoding: .utf8) ?? ""
        let message = parts.count > 1 ? String(data: Data(parts.last!), encoding: .utf8) : nil

        // Compute approximate distance
        var distance: Int = 999
        if let userLocation = locationService.currentLocation,
           let coords = Geohash.decode(fuzzyGeohash) {
            let alertLoc = CLLocation(latitude: coords.latitude, longitude: coords.longitude)
            distance = Int(userLocation.distance(from: alertLoc))
        }

        // Notify user
        notificationService.notifySOSNearby(
            severity: severity.rawValue,
            alertID: UUID(), // We derive from packet
            distance: distance,
            message: message
        )

        // Refresh visible alerts
        await refreshVisibleAlerts()
    }

    private func handleSOSAccepted(_ packet: Packet) async {
        let uuidString = String(data: packet.payload, encoding: .utf8) ?? ""
        guard let alertID = UUID(uuidString: uuidString) else { return }

        // If this is our alert, update state
        if activeAlert?.id == alertID {
            let context = ModelContext(modelContainer)
            if let alert = activeAlert {
                alert.status = .accepted
                do {
                    try context.save()
                } catch {
                    logger.error("Failed to save accepted SOS alert status: \(error.localizedDescription)")
                }
            }
            flowState = .responderAccepted(
                alertID: alertID,
                responderName: "Responder \(packet.senderID.description.prefix(8))"
            )
            if let activeAlert {
                await broadcastSOSPreciseLocation(activeAlert)
            }
        }

        await refreshVisibleAlerts()
    }

    private func handleIncomingPreciseLocation(_ packet: Packet) async {
        func decodeUInt64(from data: Data) -> UInt64? {
            guard data.count == MemoryLayout<UInt64>.size else { return nil }
            var value: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer)
            }
            return UInt64(littleEndian: value)
        }

        let payload = packet.payload
        guard let separatorIndex = payload.firstIndex(of: 0x00) else { return }

        let uuidData = payload[..<separatorIndex]
        guard let uuidString = String(data: uuidData, encoding: .utf8),
              let alertID = UUID(uuidString: uuidString) else { return }

        let coordinateBytes = payload.index(after: separatorIndex)
        let requiredLength = MemoryLayout<UInt64>.size * 2
        guard payload.distance(from: coordinateBytes, to: payload.endIndex) >= requiredLength else { return }

        let latitudeBitsData = Data(payload[coordinateBytes..<payload.index(coordinateBytes, offsetBy: MemoryLayout<UInt64>.size)])
        let longitudeStart = payload.index(coordinateBytes, offsetBy: MemoryLayout<UInt64>.size)
        let longitudeBitsData = Data(payload[longitudeStart..<payload.index(longitudeStart, offsetBy: MemoryLayout<UInt64>.size)])

        guard let latitudeBits = decodeUInt64(from: latitudeBitsData),
              let longitudeBits = decodeUInt64(from: longitudeBitsData) else { return }

        let preciseLocation = GeoPoint(
            latitude: Double(bitPattern: latitudeBits),
            longitude: Double(bitPattern: longitudeBits)
        )

        let context = ModelContext(modelContainer)
        do {
            if let storedAlert = try context.fetch(FetchDescriptor<SOSAlert>())
                .first(where: { $0.id == alertID }) {
                storedAlert.preciseLocation = preciseLocation
                try context.save()
                if acceptedAlert?.id == alertID {
                    acceptedAlert = storedAlert
                }
            } else if acceptedAlert?.id == alertID {
                acceptedAlert?.preciseLocation = preciseLocation
            }
        } catch {
            logger.error("Failed to persist SOS precise location: \(error.localizedDescription)")
        }

        await refreshVisibleAlerts()
    }

    private func handleSOSResolved(_ packet: Packet) async {
        let uuidString = String(data: packet.payload, encoding: .utf8) ?? ""
        guard let alertID = UUID(uuidString: uuidString) else { return }

        notificationService.notifySOSResolved(alertID: alertID)
        await refreshVisibleAlerts()
    }

    private func handleNearbyAssistRequest(_ packet: Packet) {
        // Nearby assist is a nudge to help -- just notify
        notificationService.notifySOSNearby(
            severity: "green",
            alertID: UUID(),
            distance: 50,
            message: "Someone nearby may need assistance"
        )
    }

    // MARK: - Private: Confirmation Countdown

    private func startConfirmationCountdown(severity: SOSSeverity) {
        flowState = .confirmingAlert(severity: severity)

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.confirmationCountdown -= 1
                if self.confirmationCountdown <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                }
            }
        }
    }

    // MARK: - Reset

    /// Reset all SOS state.
    func reset() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        flowState = .idle
        activeAlert = nil
        selectedSeverity = nil
        alertDescription = ""
        confirmationCountdown = 0
        isAcquiringGPS = false
        gpsProgress = 0
        errorMessage = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let shouldBroadcastPacket = Notification.Name("com.blip.shouldBroadcastPacket")
}

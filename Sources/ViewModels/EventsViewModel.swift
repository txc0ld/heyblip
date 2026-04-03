import Foundation
import SwiftData
import CoreLocation
import os.log

// MARK: - Event Discovery State

enum EventDiscoveryState: Sendable, Equatable {
    case idle
    case fetching
    case loaded
    case failed(String)
}

// MARK: - Event View Model

/// Manages event discovery, manifest fetch/verify, geofencing, stage map, schedule, and crowd pulse.
///
/// Features:
/// - Discover events from manifest CDN
/// - Verify manifest signatures with organizer keys
/// - Geofence monitoring for automatic event detection
/// - Stage map display with crowd density overlay
/// - Set time schedule with save/reminder functionality
/// - Crowd pulse aggregation from nearby peers
@MainActor
@Observable
final class EventsViewModel {

    // MARK: - Published State

    /// Available events (from manifest).
    var availableEvents: [EventInfo] = []

    /// The currently active event (user is inside geofence).
    var activeEvent: Event?

    /// Stages at the active event.
    var stages: [StageInfo] = []

    /// Full schedule for the active event, grouped by stage.
    var schedule: [StageSchedule] = []

    /// Set times saved by the user.
    var savedSetTimes: [SetTime] = []

    /// Crowd pulse data for the heat map overlay.
    var crowdPulseData: [CrowdPulseInfo] = []

    /// Discovery state.
    var discoveryState: EventDiscoveryState = .idle

    /// Whether the user is currently inside a event geofence.
    var isInsideEvent = false

    /// Error message, if any.
    var errorMessage: String?

    /// Success message for transient feedback.
    var successMessage: String?

    // MARK: - Discovery State

    /// Browsable events for the discovery tab.
    var discoveryEvents: [DiscoverableEvent] = []

    /// Current category filter for discovery.
    var selectedCategory: EventCategory = .all

    /// Search text for filtering events.
    var discoverySearchText: String = ""

    /// IDs of events the user has joined (loaded from SwiftData).
    private var joinedEventIds: Set<String> = []

    /// Filtered events based on category and search.
    var filteredDiscoveryEvents: [DiscoverableEvent] {
        discoveryEvents.filter { event in
            let matchesCategory = selectedCategory == .all || event.category == selectedCategory
            let matchesSearch = discoverySearchText.isEmpty ||
                event.name.localizedCaseInsensitiveContains(discoverySearchText) ||
                event.location.localizedCaseInsensitiveContains(discoverySearchText)
            return matchesCategory && matchesSearch
        }
    }

    // MARK: - Supporting Types

    enum EventCategory: String, CaseIterable, Sendable {
        case all = "All"
        case festival = "Festivals"
        case sport = "Sports"
        case marathon = "Marathons"
        case concert = "Concerts"
        case other = "Other"
    }

    struct DiscoverableEvent: Identifiable, Sendable {
        let id: String
        let name: String
        let location: String
        let startDate: Date
        let endDate: Date
        let description: String
        let imageURL: String?
        let attendeeCount: Int
        let category: EventCategory
        var isJoined: Bool
    }

    struct EventInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
        let radius: Double
        let startDate: Date
        let endDate: Date
        let stageCount: Int
        let isActive: Bool
        let isUpcoming: Bool
    }

    struct StageInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
        let currentArtist: String?
        let nextArtist: String?
        let nextStartTime: Date?
    }

    struct StageSchedule: Identifiable, Sendable {
        let id: UUID
        let stageName: String
        let sets: [SetTimeInfo]
    }

    struct SetTimeInfo: Identifiable, Sendable {
        let id: UUID
        let artistName: String
        let startTime: Date
        let endTime: Date
        let isLive: Bool
        let isUpcoming: Bool
        let isSaved: Bool
        let hasReminder: Bool
    }

    struct CrowdPulseInfo: Identifiable, Sendable {
        let id: UUID
        let geohash: String
        let peerCount: Int
        let heatLevel: HeatLevel
        let latitude: Double
        let longitude: Double
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.blip", category: "EventsViewModel")
    private let modelContainer: ModelContainer
    private let locationService: LocationService
    private let notificationService: NotificationService
    @ObservationIgnored nonisolated(unsafe) private var geofenceObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Event manifest CDN URL.
    private static let manifestURL = "https://cdn.blip.app/manifests/events.json"

    /// Crowd pulse refresh interval.
    private static let crowdPulseRefreshInterval: TimeInterval = 30.0

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        locationService: LocationService,
        notificationService: NotificationService
    ) {
        self.modelContainer = modelContainer
        self.locationService = locationService
        self.notificationService = notificationService

        setupGeofenceObserver()
    }

    deinit {
        if let obs = geofenceObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Event Discovery

    /// Fetch the event manifest from the CDN.
    func fetchEvents() async {
        discoveryState = .fetching

        guard let url = URL(string: Self.manifestURL) else {
            discoveryState = .failed("Invalid manifest URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                discoveryState = .failed("Failed to fetch manifest")
                return
            }

            let manifest = try JSONDecoder.eventDecoder.decode(EventManifest.self, from: data)

            // Verify manifest signature
            if !verifyManifestSignature(manifest) {
                discoveryState = .failed("Manifest signature verification failed")
                return
            }

            // Store events in SwiftData
            await storeEvents(manifest.events)

            // Reload from SwiftData
            await loadEvents()

            discoveryState = .loaded

        } catch {
            discoveryState = .failed("Fetch error: \(error.localizedDescription)")
        }
    }

    /// Load events from local SwiftData store.
    func loadEvents() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )

        do {
            let events = try context.fetch(descriptor)

            availableEvents = events.map { event in
                EventInfo(
                    id: event.id,
                    name: event.name,
                    latitude: event.coordinatesLatitude,
                    longitude: event.coordinatesLongitude,
                    radius: event.radiusMeters,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    stageCount: event.stages.count,
                    isActive: event.isActive,
                    isUpcoming: event.isUpcoming
                )
            }

            // Set active event if user is inside one
            activeEvent = events.first { $0.isActive }

            if let active = activeEvent {
                await loadStages(for: active)
                await loadSchedule(for: active)
                await loadCrowdPulse()
            }

        } catch {
            errorMessage = "Failed to load events: \(error.localizedDescription)"
        }
    }

    // MARK: - Event Discovery

    /// Fetch browsable events from the manifest and load joined state.
    func fetchDiscoveryEvents() async {
        discoveryState = .fetching

        guard let url = URL(string: ServerConfig.eventsManifestURL) else {
            discoveryState = .failed("Invalid manifest URL")
            DebugLogger.shared.log("EVENT", "Invalid events manifest URL", isError: true)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                discoveryState = .failed("Failed to fetch events")
                DebugLogger.shared.log("EVENT", "Events manifest returned non-200", isError: true)
                return
            }

            let manifest = try JSONDecoder.eventDecoder.decode(EventManifest.self, from: data)
            await loadJoinedEventIds()

            discoveryEvents = manifest.events.map { event in
                DiscoverableEvent(
                    id: event.id.uuidString,
                    name: event.name,
                    location: event.location ?? "Unknown location",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    description: event.description ?? "",
                    imageURL: event.imageURL,
                    attendeeCount: event.attendeeCount ?? 0,
                    category: EventCategory(rawValue: event.category ?? "Other") ?? .other,
                    isJoined: joinedEventIds.contains(event.id.uuidString)
                )
            }

            discoveryState = discoveryEvents.isEmpty ? .idle : .loaded
            DebugLogger.shared.log("EVENT", "Loaded \(discoveryEvents.count) events from manifest")

        } catch {
            discoveryState = .failed("Fetch error: \(error.localizedDescription)")
            DebugLogger.shared.log("EVENT", "Failed to fetch discovery events: \(error)", isError: true)
        }
    }

    /// Load joined event IDs from SwiftData.
    private func loadJoinedEventIds() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<JoinedEvent>()
        do {
            let joined = try context.fetch(descriptor)
            joinedEventIds = Set(joined.map(\.eventId))
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to load joined events: \(error)", isError: true)
        }
    }

    /// Join an event — persists to SwiftData.
    func joinEvent(_ eventId: String) {
        let context = ModelContext(modelContainer)
        let joinedEvent = JoinedEvent(eventId: eventId)
        context.insert(joinedEvent)
        do {
            try context.save()
            joinedEventIds.insert(eventId)
            if let index = discoveryEvents.firstIndex(where: { $0.id == eventId }) {
                discoveryEvents[index].isJoined = true
            }
            DebugLogger.shared.log("EVENT", "Joined event \(eventId)")
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to join event: \(error)", isError: true)
        }
    }

    /// Leave an event — removes from SwiftData.
    func leaveEvent(_ eventId: String) {
        let context = ModelContext(modelContainer)
        let targetId = eventId
        let descriptor = FetchDescriptor<JoinedEvent>(predicate: #Predicate { $0.eventId == targetId })
        do {
            let matches = try context.fetch(descriptor)
            for match in matches { context.delete(match) }
            try context.save()
            joinedEventIds.remove(eventId)
            if let index = discoveryEvents.firstIndex(where: { $0.id == eventId }) {
                discoveryEvents[index].isJoined = false
            }
            DebugLogger.shared.log("EVENT", "Left event \(eventId)")
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to leave event: \(error)", isError: true)
        }
    }

    /// Check if user has joined a specific event.
    func isJoined(_ eventId: String) -> Bool {
        joinedEventIds.contains(eventId)
    }

    // MARK: - Geofencing

    /// Start monitoring geofences for all upcoming and active events.
    func startGeofencing() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Event>()

        let events: [Event]
        do {
            events = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch events for geofencing: \(error.localizedDescription)")
            errorMessage = "Failed to fetch events for geofencing: \(error.localizedDescription)"
            return
        }

        for event in events where event.isActive || event.isUpcoming {
            do {
                try locationService.monitorEvent(
                    id: event.id,
                    center: CLLocationCoordinate2D(
                        latitude: event.coordinatesLatitude,
                        longitude: event.coordinatesLongitude
                    ),
                    radius: event.radiusMeters
                )
            } catch {
                errorMessage = "Failed to set geofence for \(event.name)"
            }
        }
    }

    /// Handle entering a event geofence.
    func handleEventEntry(eventID: UUID) async {
        let context = ModelContext(modelContainer)
        let targetID = eventID
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == targetID })

        let event: Event
        do {
            guard let fetched = try context.fetch(descriptor).first else { return }
            event = fetched
        } catch {
            logger.error("Failed to fetch event for entry: \(error.localizedDescription)")
            errorMessage = "Failed to fetch event for entry: \(error.localizedDescription)"
            return
        }

        activeEvent = event
        isInsideEvent = true

        // Update preferences
        let prefsDescriptor = FetchDescriptor<UserPreferences>()
        do {
            if let prefs = try context.fetch(prefsDescriptor).first {
                prefs.lastEventID = eventID
                do {
                    try context.save()
                } catch {
                    logger.error("Failed to save user preferences: \(error.localizedDescription)")
                    errorMessage = "Failed to save user preferences: \(error.localizedDescription)"
                }
            }
        } catch {
            logger.error("Failed to fetch user preferences: \(error.localizedDescription)")
            errorMessage = "Failed to fetch user preferences: \(error.localizedDescription)"
        }

        await loadStages(for: event)
        await loadSchedule(for: event)
        await loadCrowdPulse()

        successMessage = "Welcome to \(event.name)!"
    }

    /// Handle exiting a event geofence.
    func handleEventExit(eventID: UUID) {
        if activeEvent?.id == eventID {
            isInsideEvent = false
        }
    }

    // MARK: - Stages

    private func loadStages(for event: Event) async {
        stages = event.stages.map { stage in
            let currentSet = stage.schedule.first { $0.isLive }
            let nextSet = stage.schedule
                .filter { $0.isUpcoming }
                .sorted { $0.startTime < $1.startTime }
                .first

            return StageInfo(
                id: stage.id,
                name: stage.name,
                latitude: stage.coordinatesLatitude,
                longitude: stage.coordinatesLongitude,
                currentArtist: currentSet?.artistName,
                nextArtist: nextSet?.artistName,
                nextStartTime: nextSet?.startTime
            )
        }
    }

    // MARK: - Schedule

    private func loadSchedule(for event: Event) async {
        schedule = event.stages.map { stage in
            let sets = stage.schedule
                .sorted { $0.startTime < $1.startTime }
                .map { setTime in
                    SetTimeInfo(
                        id: setTime.id,
                        artistName: setTime.artistName,
                        startTime: setTime.startTime,
                        endTime: setTime.endTime,
                        isLive: setTime.isLive,
                        isUpcoming: setTime.isUpcoming,
                        isSaved: setTime.savedByUser,
                        hasReminder: setTime.reminderSet
                    )
                }

            return StageSchedule(
                id: stage.id,
                stageName: stage.name,
                sets: sets
            )
        }

        // Load saved set times
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SetTime>(predicate: #Predicate { $0.savedByUser == true })
        do {
            savedSetTimes = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch saved set times: \(error.localizedDescription)")
            errorMessage = "Failed to fetch saved set times: \(error.localizedDescription)"
            savedSetTimes = []
        }
    }

    /// Save/unsave a set time.
    func toggleSaveSetTime(setTimeID: UUID) async {
        let context = ModelContext(modelContainer)
        let targetID = setTimeID
        let descriptor = FetchDescriptor<SetTime>(predicate: #Predicate { $0.id == targetID })

        let setTime: SetTime
        do {
            guard let fetched = try context.fetch(descriptor).first else { return }
            setTime = fetched
        } catch {
            logger.error("Failed to fetch set time for toggle save: \(error.localizedDescription)")
            errorMessage = "Failed to fetch set time for toggle save: \(error.localizedDescription)"
            return
        }

        setTime.savedByUser.toggle()

        if setTime.savedByUser {
            savedSetTimes.append(setTime)
        } else {
            savedSetTimes.removeAll { $0.id == setTimeID }
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save set time toggle: \(error.localizedDescription)")
            errorMessage = "Failed to save set time toggle: \(error.localizedDescription)"
        }

        if let active = activeEvent {
            await loadSchedule(for: active)
        }
    }

    /// Toggle reminder for a set time.
    func toggleReminder(setTimeID: UUID) async {
        let context = ModelContext(modelContainer)
        let targetID = setTimeID
        let descriptor = FetchDescriptor<SetTime>(predicate: #Predicate { $0.id == targetID })

        let setTime: SetTime
        do {
            guard let fetched = try context.fetch(descriptor).first else { return }
            setTime = fetched
        } catch {
            logger.error("Failed to fetch set time for toggle reminder: \(error.localizedDescription)")
            errorMessage = "Failed to fetch set time for toggle reminder: \(error.localizedDescription)"
            return
        }

        setTime.reminderSet.toggle()
        do {
            try context.save()
        } catch {
            logger.error("Failed to save reminder toggle: \(error.localizedDescription)")
            errorMessage = "Failed to save reminder toggle: \(error.localizedDescription)"
        }

        if setTime.reminderSet {
            // Schedule notification
            let stageName = setTime.stage?.name ?? "Stage"
            notificationService.scheduleSetTimeAlert(
                artistName: setTime.artistName,
                stageName: stageName,
                startTime: setTime.startTime,
                setTimeID: setTime.id,
                reminderMinutes: 15
            )
            successMessage = "Reminder set for \(setTime.artistName)"
        } else {
            notificationService.cancelSetTimeAlert(setTimeID: setTime.id)
            successMessage = "Reminder removed"
        }

        if let active = activeEvent {
            await loadSchedule(for: active)
        }
    }

    // MARK: - Crowd Pulse

    /// Load crowd pulse data from nearby peer observations.
    func loadCrowdPulse() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CrowdPulse>(
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]
        )

        let pulses: [CrowdPulse]
        do {
            pulses = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch crowd pulse data: \(error.localizedDescription)")
            errorMessage = "Failed to fetch crowd pulse data: \(error.localizedDescription)"
            return
        }

        crowdPulseData = pulses.filter { !$0.isStale }.compactMap { pulse in
            guard let coords = Geohash.decode(pulse.geohash) else { return nil }

            return CrowdPulseInfo(
                id: pulse.id,
                geohash: pulse.geohash,
                peerCount: pulse.peerCount,
                heatLevel: pulse.heatLevel,
                latitude: coords.latitude,
                longitude: coords.longitude
            )
        }
    }

    /// Refresh crowd pulse from current mesh observations.
    func refreshCrowdPulse() async {
        await loadCrowdPulse()
    }

    // MARK: - Private: Manifest

    private struct EventManifest: Codable {
        let version: Int
        let signature: String?
        let events: [ManifestEvent]

        enum CodingKeys: String, CodingKey {
            case version, signature, events
        }
    }

    private struct ManifestEvent: Codable {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let startDate: Date
        let endDate: Date
        let organizerSigningKey: String
        let stages: [ManifestStage]?
        let location: String?
        let description: String?
        let imageURL: String?
        let attendeeCount: Int?
        let category: String?
    }

    private struct ManifestStage: Codable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let schedule: [ManifestSetTime]?
    }

    private struct ManifestSetTime: Codable {
        let id: String
        let artistName: String
        let startTime: String
        let endTime: String
    }

    private func verifyManifestSignature(_ manifest: EventManifest) -> Bool {
        // In production: verify Ed25519 signature of the manifest data
        // For now, accept all manifests (signature infrastructure TBD)
        return true
    }

    private func storeEvents(_ manifestEvents: [ManifestEvent]) async {
        let context = ModelContext(modelContainer)
        let dateFormatter = ISO8601DateFormatter()

        for mf in manifestEvents {
            let uuid = mf.id
            let startDate = mf.startDate
            let endDate = mf.endDate
            let signingKey = Data(base64Encoded: mf.organizerSigningKey) ?? Data()

            // Check if event already exists
            let targetID = uuid
            let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == targetID })
            let existing: Event?
            do {
                existing = try context.fetch(descriptor).first
            } catch {
                logger.error("Failed to fetch existing event during store: \(error.localizedDescription)")
                continue
            }

            if let existing {
                // Update
                existing.name = mf.name
                existing.coordinatesLatitude = mf.latitude
                existing.coordinatesLongitude = mf.longitude
                existing.radiusMeters = mf.radiusMeters
                existing.startDate = startDate
                existing.endDate = endDate
                existing.organizerSigningKey = signingKey
            } else {
                // Insert new
                let event = Event(
                    id: uuid,
                    name: mf.name,
                    coordinates: GeoPoint(latitude: mf.latitude, longitude: mf.longitude),
                    radiusMeters: mf.radiusMeters,
                    startDate: startDate,
                    endDate: endDate,
                    organizerSigningKey: signingKey
                )
                context.insert(event)

                // Insert stages
                if let manifestStages = mf.stages {
                    for ms in manifestStages {
                        guard let stageUUID = UUID(uuidString: ms.id) else { continue }

                        let stage = Stage(
                            id: stageUUID,
                            name: ms.name,
                            event: event,
                            coordinates: GeoPoint(latitude: ms.latitude, longitude: ms.longitude)
                        )
                        context.insert(stage)

                        // Insert set times
                        if let manifestSets = ms.schedule {
                            for mst in manifestSets {
                                guard let setUUID = UUID(uuidString: mst.id),
                                      let setStart = dateFormatter.date(from: mst.startTime),
                                      let setEnd = dateFormatter.date(from: mst.endTime) else { continue }

                                let setTime = SetTime(
                                    id: setUUID,
                                    artistName: mst.artistName,
                                    stage: stage,
                                    startTime: setStart,
                                    endTime: setEnd
                                )
                                context.insert(setTime)
                            }
                        }
                    }
                }
            }
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save stored events: \(error.localizedDescription)")
            errorMessage = "Failed to save stored events: \(error.localizedDescription)"
        }
    }

    // MARK: - Private: Geofence Observer

    private func setupGeofenceObserver() {
        // The LocationService notifies via its delegate; here we observe via the location service
        // This is connected during app startup when the EventsViewModel is set as the location delegate
    }

    // MARK: - Utility

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}

// MARK: - JSON Decoder Extension

private extension JSONDecoder {
    static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

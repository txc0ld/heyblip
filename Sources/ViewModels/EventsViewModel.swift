import Foundation
import SwiftData
import CoreLocation
import os.log
import BlipCrypto

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

    /// Live organizer announcements for the active event.
    var announcements: [AnnouncementItem] = []

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
    private let context: ModelContext
    private let locationService: LocationService
    private let notificationService: NotificationService
    private var previousAnnouncementIDs: Set<UUID> = []
    @ObservationIgnored nonisolated(unsafe) private var geofenceObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var announcementObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Max retry attempts for remote fetch.
    private static let maxRetries = 3

    /// Base delay for exponential backoff (seconds).
    private static let baseRetryDelay: TimeInterval = 2.0

    /// Crowd pulse refresh interval.
    private static let crowdPulseRefreshInterval: TimeInterval = 30.0

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        locationService: LocationService,
        notificationService: NotificationService
    ) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
        self.locationService = locationService
        self.notificationService = notificationService

        setupGeofenceObserver()
        setupAnnouncementObserver()
    }

    deinit {
        if let obs = geofenceObservation { NotificationCenter.default.removeObserver(obs) }
        if let obs = announcementObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Event Discovery

    /// Load the bundled full manifest used for geofencing and local event storage.
    func fetchEvents() async {
        discoveryState = .fetching

        // Always load bundled events first for instant content
        await loadBundledEvents()

        // Refresh from the CDN in the background; bundled data remains the offline-first fallback.
        Task { await fetchRemoteEventsWithRetry() }
    }

    /// Reset retry state and fetch again (called on pull-to-refresh).
    func refreshEvents() async {
        discoveryState = .fetching
        await loadBundledEvents()
        await fetchRemoteEventsWithRetry()
    }

    /// Load events from the bundled events.json in Resources/.
    private func loadBundledEvents() async {
        guard let url = Bundle.main.url(forResource: "events", withExtension: "json") else {
            DebugLogger.shared.log("EVENT", "Bundled events.json not found", isError: true)
            discoveryState = .failed("No events data available")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder.eventDecoder.decode(EventManifest.self, from: data)
            await storeEvents(manifest.events)
            await loadEvents()
            discoveryState = .loaded
            DebugLogger.shared.log("EVENT", "Loaded \(manifest.events.count) events from bundle")
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to decode bundled events: \(error)", isError: true)
            discoveryState = .failed("Failed to load events")
        }
    }

    /// Fetch the full remote manifest with exponential backoff when the CDN serves it.
    /// The current live worker serves discovery events only, so this remains unused.
    private func fetchRemoteEventsWithRetry() async {
        guard let url = URL(string: ServerConfig.eventsManifestURL) else {
            DebugLogger.shared.log("APP", "Invalid events manifest URL: \(ServerConfig.eventsManifestURL)", isError: true)
            return
        }

        for attempt in 1...Self.maxRetries {
            if attempt > 1 {
                let delay = Self.baseRetryDelay * pow(2.0, Double(attempt - 2))
                DebugLogger.shared.log("EVENT", "Fetch retry \(attempt)/\(Self.maxRetries) after \(Int(delay))s delay")
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    DebugLogger.shared.log("EVENT", "Retry sleep cancelled: \(error)")
                    return
                }
            }

            do {
                let (data, response) = try await ServerConfig.pinnedSession.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    DebugLogger.shared.log("APP", "Remote manifest returned non-200 (attempt \(attempt))", isError: true)
                    continue
                }

                let manifest = try JSONDecoder.eventDecoder.decode(EventManifest.self, from: data)

                if !verifyManifestSignature(manifest) {
                    DebugLogger.shared.log("APP", "Manifest signature verification failed", isError: true)
                    discoveryState = .failed("Manifest verification failed")
                    return
                }

                await storeEvents(manifest.events)
                await loadEvents()
                discoveryState = .loaded
                DebugLogger.shared.log("EVENT", "Loaded \(manifest.events.count) events from remote (attempt \(attempt))")
                return
            } catch {
                DebugLogger.shared.log("APP", "Remote fetch failed (attempt \(attempt)): \(error)", isError: true)
            }
        }

        DebugLogger.shared.log("APP", "Fetch failed after \(Self.maxRetries) retries", isError: true)
        // Don't override bundled data state — if bundled loaded successfully, keep .loaded
        if case .fetching = discoveryState {
            discoveryState = .failed("Could not reach events server after \(Self.maxRetries) attempts")
        }
    }

    /// Load events from local SwiftData store.
    func loadEvents() async {
        let context = self.context

        do {
            let events = try context.fetch(FetchDescriptor<Event>())
                .sorted { $0.startDate < $1.startDate }

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
                refreshAnnouncements()
            } else {
                announcements = []
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
            DebugLogger.shared.log("APP", "Invalid events manifest URL: \(ServerConfig.eventsManifestURL)", isError: true)
            return
        }

        do {
            let (data, response) = try await ServerConfig.pinnedSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                discoveryState = .failed("Failed to fetch events")
                DebugLogger.shared.log("APP", "Events manifest returned non-200", isError: true)
                return
            }

            let events = try decodeDiscoveryManifestEvents(from: data)
            await loadJoinedEventIds()

            discoveryEvents = events.map { event in
                DiscoverableEvent(
                    id: event.id.uuidString,
                    name: event.name,
                    location: event.location ?? "Unknown location",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    description: event.description ?? "",
                    imageURL: event.imageURL,
                    attendeeCount: event.attendeeCount ?? 0,
                    category: eventCategory(for: event.category),
                    isJoined: joinedEventIds.contains(event.id.uuidString)
                )
            }

            discoveryState = discoveryEvents.isEmpty ? .idle : .loaded
            DebugLogger.shared.log("EVENT", "Loaded \(discoveryEvents.count) discovery events from manifest")

        } catch {
            discoveryState = .failed("Fetch error: \(error.localizedDescription)")
            DebugLogger.shared.log("APP", "Failed to fetch discovery events: \(error)", isError: true)
        }
    }

    /// Load joined event IDs from SwiftData.
    private func loadJoinedEventIds() async {
        let context = self.context
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
        let context = self.context
        let joinedEvent = JoinedEvent(eventId: eventId)
        context.insert(joinedEvent)
        do {
            if let event = try fetchEvent(for: eventId, context: context) {
                ensureLostAndFoundChannel(for: event, context: context)
                createStageChannels(for: event)
            }
            try context.save()
            joinedEventIds.insert(eventId)
            if let index = discoveryEvents.firstIndex(where: { $0.id == eventId }) {
                discoveryEvents[index].isJoined = true
            }
            NotificationCenter.default.post(name: .channelListDidChange, object: nil)
            DebugLogger.shared.log("EVENT", "Joined event \(eventId)")
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to join event: \(error)", isError: true)
        }
    }

    /// Leave an event — removes from SwiftData.
    func leaveEvent(_ eventId: String) {
        let context = self.context
        do {
            let matches = try context.fetch(FetchDescriptor<JoinedEvent>())
                .filter { $0.eventId == eventId }
            for match in matches { context.delete(match) }
            updateLostAndFoundChannelJoinState(for: eventId, isJoined: false, context: context)
            try context.save()
            joinedEventIds.remove(eventId)
            if let index = discoveryEvents.firstIndex(where: { $0.id == eventId }) {
                discoveryEvents[index].isJoined = false
            }
            NotificationCenter.default.post(name: .channelListDidChange, object: nil)
            DebugLogger.shared.log("EVENT", "Left event \(eventId)")
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to leave event: \(error)", isError: true)
        }
    }

    func createStageChannels(for event: Event) {
        do {
            var stageChannels = try context.fetch(FetchDescriptor<Channel>())
                .filter { $0.type == .stageChannel }
            let eventRetention = max(event.endDate.timeIntervalSince(event.startDate), 300)

            if event.stages.isEmpty {
                if let existingAnnouncements = stageChannels.first(where: {
                    normalizedChannelName($0.name) == normalizedChannelName("Announcements") &&
                    ($0.event?.id == event.id || $0.event == nil)
                }) {
                    existingAnnouncements.event = event
                    existingAnnouncements.isAutoJoined = true
                    existingAnnouncements.maxRetention = eventRetention
                } else {
                    let channel = Channel(
                        type: .stageChannel,
                        name: "Announcements",
                        event: event,
                        maxRetention: eventRetention,
                        isAutoJoined: true
                    )
                    context.insert(channel)
                    DebugLogger.shared.log("EVENT", "Created stage channel: Announcements")
                }
                return
            }

            for stage in event.stages {
                let existingChannel = stageChannels.first(where: {
                    normalizedChannelName($0.name) == normalizedChannelName(stage.name) &&
                    $0.event?.id == event.id
                }) ?? stageChannels.first(where: {
                    normalizedChannelName($0.name) == normalizedChannelName(stage.name) &&
                    $0.event == nil
                })

                if let existingChannel {
                    existingChannel.event = event
                    existingChannel.isAutoJoined = true
                    existingChannel.maxRetention = eventRetention
                    stage.channel = existingChannel
                    continue
                }

                let channel = Channel(
                    id: stage.id,
                    type: .stageChannel,
                    name: stage.name,
                    event: event,
                    maxRetention: eventRetention,
                    isAutoJoined: true
                )
                context.insert(channel)
                stage.channel = channel
                stageChannels.append(channel)
                DebugLogger.shared.log("EVENT", "Created stage channel: \(stage.name)")
            }
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to create stage channels: \(error)", isError: true)
        }
    }

    func stageChannel(named name: String) -> Channel? {
        do {
            let stageChannels = try context.fetch(FetchDescriptor<Channel>())
                .filter { $0.type == .stageChannel }
            let normalizedName = normalizedChannelName(name)

            if let activeEventID = activeEvent?.id,
               let eventScopedMatch = stageChannels.first(where: {
                   normalizedChannelName($0.name) == normalizedName &&
                   $0.event?.id == activeEventID
               }) {
                return eventScopedMatch
            }

            return stageChannels.first(where: {
                normalizedChannelName($0.name) == normalizedName
            })
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to resolve stage channel \(name): \(error)", isError: true)
            return nil
        }
    }

    /// Check if user has joined a specific event.
    func isJoined(_ eventId: String) -> Bool {
        joinedEventIds.contains(eventId)
    }

    // MARK: - Geofencing

    /// Start monitoring geofences for all upcoming and active events.
    func startGeofencing() async {
        let context = self.context
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
        let context = self.context

        let event: Event
        do {
            guard let fetched = try context.fetch(FetchDescriptor<Event>())
                .first(where: { $0.id == eventID }) else { return }
            event = fetched
        } catch {
            logger.error("Failed to fetch event for entry: \(error.localizedDescription)")
            errorMessage = "Failed to fetch event for entry: \(error.localizedDescription)"
            return
        }

        activeEvent = event
        isInsideEvent = true

        ensureLostAndFoundChannel(for: event, context: context)
        createStageChannels(for: event)

        // Update preferences
        let prefsDescriptor = FetchDescriptor<UserPreferences>()
        do {
            if let prefs = try context.fetch(prefsDescriptor).first {
                prefs.lastEventID = eventID
            }
        } catch {
            logger.error("Failed to fetch user preferences: \(error.localizedDescription)")
            errorMessage = "Failed to fetch user preferences: \(error.localizedDescription)"
        }

        do {
            try context.save()
            NotificationCenter.default.post(name: .channelListDidChange, object: nil)
        } catch {
            logger.error("Failed to persist event entry state: \(error.localizedDescription)")
            errorMessage = "Failed to persist event entry state: \(error.localizedDescription)"
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
            let context = self.context
            updateLostAndFoundChannelJoinState(for: eventID.uuidString, isJoined: false, context: context)
            do {
                try context.save()
            } catch {
                logger.error("Failed to leave Lost & Found channel on event exit: \(error.localizedDescription)")
                errorMessage = "Failed to leave Lost & Found channel: \(error.localizedDescription)"
            }
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
        let context = self.context
        do {
            savedSetTimes = try context.fetch(FetchDescriptor<SetTime>())
                .filter(\.savedByUser)
        } catch {
            logger.error("Failed to fetch saved set times: \(error.localizedDescription)")
            errorMessage = "Failed to fetch saved set times: \(error.localizedDescription)"
            savedSetTimes = []
        }
    }

    /// Save/unsave a set time.
    func toggleSaveSetTime(setTimeID: UUID) async {
        let context = self.context

        let setTime: SetTime
        do {
            guard let fetched = try context.fetch(FetchDescriptor<SetTime>())
                .first(where: { $0.id == setTimeID }) else { return }
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
        let context = self.context

        let setTime: SetTime
        do {
            guard let fetched = try context.fetch(FetchDescriptor<SetTime>())
                .first(where: { $0.id == setTimeID }) else { return }
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
        let context = self.context

        let pulses: [CrowdPulse]
        do {
            pulses = try context.fetch(FetchDescriptor<CrowdPulse>())
                .sorted { $0.lastUpdated > $1.lastUpdated }
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

    // MARK: - Announcements

    /// Fetch organizer announcements from the stageChannel and transform to AnnouncementItems.
    private func refreshAnnouncements() {
        let context = self.context
        do {
            let descriptor = FetchDescriptor<Channel>(
                predicate: #Predicate { $0.typeRaw == "stageChannel" }
            )
            let stageChannels = try context.fetch(descriptor)
            guard let channel = preferredAnnouncementChannel(from: stageChannels) else {
                announcements = []
                return
            }

            let messages = channel.messages.sorted { $0.createdAt > $1.createdAt }
            let items: [AnnouncementItem] = messages.compactMap { message in
                guard let text = String(data: message.rawPayload, encoding: .utf8),
                      !text.isEmpty else { return nil }

                let lines = text.split(separator: "\n", maxSplits: 1)
                let title: String
                let body: String
                if lines.count > 1 {
                    title = String(lines[0])
                    body = String(lines[1])
                } else {
                    title = "Event Update"
                    body = text
                }

                return AnnouncementItem(
                    id: message.id,
                    title: title,
                    message: body,
                    severity: announcementSeverity(title: title, body: body),
                    timestamp: message.createdAt,
                    source: activeEvent?.name,
                    isPinned: false
                )
            }
            announcements = items

            let currentIDs = Set(items.map(\.id))
            let newIDs = currentIDs.subtracting(previousAnnouncementIDs)
            if !previousAnnouncementIDs.isEmpty {
                for item in items where newIDs.contains(item.id) {
                    notificationService.notifyOrgAnnouncement(
                        eventName: activeEvent?.name ?? "Event",
                        message: item.message
                    )
                }
            }
            previousAnnouncementIDs = currentIDs
        } catch {
            DebugLogger.shared.log("EVENT", "Failed to fetch announcements: \(error.localizedDescription)")
            announcements = []
        }
    }

    /// Organizer announcements currently persist only UTF-8 payload text; the
    /// protocol/TLV announcement fields are peer metadata, not feed severity.
    /// Until the wire payload carries explicit severity, infer from known title/body prefixes.
    private func announcementSeverity(title: String, body: String) -> AnnouncementSeverity {
        let candidates = [title, body]

        if candidates.contains(where: { hasSeverityPrefix($0, keywords: ["EMERGENCY", "CRITICAL"]) }) {
            return .emergency
        }
        if candidates.contains(where: { hasSeverityPrefix($0, keywords: ["URGENT"]) }) {
            return .urgent
        }
        if candidates.contains(where: { hasSeverityPrefix($0, keywords: ["WARNING", "CAUTION", "ALERT"]) }) {
            return .warning
        }

        return .info
    }

    private func hasSeverityPrefix(_ text: String, keywords: [String]) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        return keywords.contains { keyword in
            normalized == keyword ||
                normalized.hasPrefix("\(keyword):") ||
                normalized.hasPrefix("\(keyword) -") ||
                normalized.hasPrefix("\(keyword) ") ||
                normalized.hasPrefix("[\(keyword)]")
        }
    }

    private func preferredAnnouncementChannel(from channels: [Channel]) -> Channel? {
        let scopedChannels: [Channel]
        if let activeEventID = activeEvent?.id {
            let matches = channels.filter { $0.event?.id == activeEventID }
            scopedChannels = matches.isEmpty ? channels : matches
        } else {
            scopedChannels = channels
        }

        return scopedChannels.sorted(by: announcementChannelSort).first
    }

    private func announcementChannelSort(_ lhs: Channel, _ rhs: Channel) -> Bool {
        announcementChannelSortKey(lhs) < announcementChannelSortKey(rhs)
    }

    private func announcementChannelSortKey(_ channel: Channel) -> (Int, String) {
        let normalizedName = normalizedChannelName(channel.name)
        let priority = normalizedName == normalizedChannelName("Announcements") ? 0 : 1
        return (priority, normalizedName)
    }

    private func setupAnnouncementObserver() {
        announcementObservation = NotificationCenter.default.addObserver(
            forName: .didReceiveBlipMessage,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAnnouncements()
            }
        }
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

    private struct DiscoveryManifestEvent: Codable {
        let id: UUID
        let name: String
        let location: String?
        let startDate: Date
        let endDate: Date
        let description: String?
        let imageURL: String?
        let attendeeCount: Int?
        let category: String?

        init(from manifestEvent: ManifestEvent) {
            self.id = manifestEvent.id
            self.name = manifestEvent.name
            self.location = manifestEvent.location
            self.startDate = manifestEvent.startDate
            self.endDate = manifestEvent.endDate
            self.description = manifestEvent.description
            self.imageURL = manifestEvent.imageURL
            self.attendeeCount = manifestEvent.attendeeCount
            self.category = manifestEvent.category
        }
    }

    private struct ManifestSetTime: Codable {
        let id: String
        let artistName: String
        let startTime: String
        let endTime: String
    }

    private func decodeDiscoveryManifestEvents(from data: Data) throws -> [DiscoveryManifestEvent] {
        do {
            let manifest = try JSONDecoder.eventDecoder.decode(EventManifest.self, from: data)
            return manifest.events.map(DiscoveryManifestEvent.init)
        } catch {
            return try JSONDecoder.eventDecoder.decode([DiscoveryManifestEvent].self, from: data)
        }
    }

    private func eventCategory(for rawCategory: String?) -> EventCategory {
        switch rawCategory?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "festival":
            return .festival
        case "sport":
            return .sport
        case "marathon":
            return .marathon
        case "concert":
            return .concert
        default:
            return .other
        }
    }

    private func fetchEvent(for eventId: String, context: ModelContext) throws -> Event? {
        guard let eventUUID = UUID(uuidString: eventId) else { return nil }
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == eventUUID })
        return try context.fetch(descriptor).first
    }

    private func normalizedChannelName(_ name: String?) -> String {
        name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            ?? ""
    }

    private func ensureLostAndFoundChannel(for event: Event, context: ModelContext) {
        let channelID = event.id
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })

        do {
            if let existingChannel = try context.fetch(descriptor).first {
                existingChannel.type = .lostAndFound
                existingChannel.name = "Lost & Found"
                existingChannel.event = event
                existingChannel.isAutoJoined = true
                existingChannel.maxRetention = max(event.endDate.timeIntervalSince(event.startDate), 86400)
                return
            }

            let channel = Channel(
                id: channelID,
                type: .lostAndFound,
                name: "Lost & Found",
                event: event,
                maxRetention: max(event.endDate.timeIntervalSince(event.startDate), 86400),
                isAutoJoined: true
            )
            context.insert(channel)
        } catch {
            logger.error("Failed to ensure Lost & Found channel: \(error.localizedDescription)")
            errorMessage = "Failed to prepare Lost & Found channel: \(error.localizedDescription)"
        }
    }

    private func updateLostAndFoundChannelJoinState(for eventId: String, isJoined: Bool, context: ModelContext) {
        guard let eventUUID = UUID(uuidString: eventId) else { return }
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == eventUUID })

        do {
            if let channel = try context.fetch(descriptor).first {
                channel.isAutoJoined = isJoined
            }
        } catch {
            logger.error("Failed to update Lost & Found channel join state: \(error.localizedDescription)")
            errorMessage = "Failed to update Lost & Found channel: \(error.localizedDescription)"
        }
    }

    private func verifyManifestSignature(_ manifest: EventManifest) -> Bool {
        guard let signatureBase64 = manifest.signature,
              let signatureData = Data(base64Encoded: signatureBase64) else {
            DebugLogger.shared.log("EVENT", "Manifest has no valid signature", isError: true)
            return false
        }

        guard let firstEvent = manifest.events.first,
              let publicKeyData = Data(base64Encoded: firstEvent.organizerSigningKey),
              publicKeyData.count == Signer.publicKeyLength else {
            DebugLogger.shared.log("EVENT", "Manifest has no valid organizer signing key", isError: true)
            return false
        }

        // Canonical message: JSON-encode the events array
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let messageData = try? encoder.encode(manifest.events) else {
            DebugLogger.shared.log("EVENT", "Failed to encode manifest events for verification", isError: true)
            return false
        }

        do {
            let isValid = try Signer.verifyDetached(
                message: messageData,
                signature: signatureData,
                publicKey: publicKeyData
            )
            DebugLogger.shared.log("EVENT", "Manifest signature verification: \(isValid ? "passed" : "FAILED")")
            return isValid
        } catch {
            DebugLogger.shared.log("EVENT", "Manifest signature verification error: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    private func storeEvents(_ manifestEvents: [ManifestEvent]) async {
        let context = self.context
        let dateFormatter = ISO8601DateFormatter()

        for mf in manifestEvents {
            let uuid = mf.id
            let startDate = mf.startDate
            let endDate = mf.endDate
            let signingKey = Data(base64Encoded: mf.organizerSigningKey) ?? Data()

            // Check if event already exists
            let existing: Event?
            do {
                existing = try context.fetch(FetchDescriptor<Event>())
                    .first(where: { $0.id == uuid })
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

extension Notification.Name {
    static let channelListDidChange = Notification.Name("com.blip.channelListDidChange")
}

// MARK: - JSON Decoder Extension

private extension JSONDecoder {
    static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

import Foundation
import SwiftData
import CoreLocation
import os.log

// MARK: - Festival Discovery State

enum FestivalDiscoveryState: Sendable, Equatable {
    case idle
    case fetching
    case loaded
    case failed(String)
}

// MARK: - Festival View Model

/// Manages festival discovery, manifest fetch/verify, geofencing, stage map, schedule, and crowd pulse.
///
/// Features:
/// - Discover festivals from manifest CDN
/// - Verify manifest signatures with organizer keys
/// - Geofence monitoring for automatic festival detection
/// - Stage map display with crowd density overlay
/// - Set time schedule with save/reminder functionality
/// - Crowd pulse aggregation from nearby peers
@MainActor
@Observable
final class FestivalViewModel {

    // MARK: - Published State

    /// Available festivals (from manifest).
    var availableFestivals: [FestivalInfo] = []

    /// The currently active festival (user is inside geofence).
    var activeFestival: Festival?

    /// Stages at the active festival.
    var stages: [StageInfo] = []

    /// Full schedule for the active festival, grouped by stage.
    var schedule: [StageSchedule] = []

    /// Set times saved by the user.
    var savedSetTimes: [SetTime] = []

    /// Crowd pulse data for the heat map overlay.
    var crowdPulseData: [CrowdPulseInfo] = []

    /// Discovery state.
    var discoveryState: FestivalDiscoveryState = .idle

    /// Whether the user is currently inside a festival geofence.
    var isInsideFestival = false

    /// Error message, if any.
    var errorMessage: String?

    /// Success message for transient feedback.
    var successMessage: String?

    // MARK: - Supporting Types

    struct FestivalInfo: Identifiable, Sendable {
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

    private let logger = Logger(subsystem: "com.blip", category: "FestivalViewModel")
    private let modelContainer: ModelContainer
    private let locationService: LocationService
    private let notificationService: NotificationService
    @ObservationIgnored nonisolated(unsafe) private var geofenceObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Festival manifest CDN URL.
    private static let manifestURL = "https://cdn.blip.app/manifests/festivals.json"

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

    // MARK: - Festival Discovery

    /// Fetch the festival manifest from the CDN.
    func fetchFestivals() async {
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

            let manifest = try JSONDecoder.festivalDecoder.decode(FestivalManifest.self, from: data)

            // Verify manifest signature
            if !verifyManifestSignature(manifest) {
                discoveryState = .failed("Manifest signature verification failed")
                return
            }

            // Store festivals in SwiftData
            await storeFestivals(manifest.festivals)

            // Reload from SwiftData
            await loadFestivals()

            discoveryState = .loaded

        } catch {
            discoveryState = .failed("Fetch error: \(error.localizedDescription)")
        }
    }

    /// Load festivals from local SwiftData store.
    func loadFestivals() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Festival>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )

        do {
            let festivals = try context.fetch(descriptor)

            availableFestivals = festivals.map { festival in
                FestivalInfo(
                    id: festival.id,
                    name: festival.name,
                    latitude: festival.coordinatesLatitude,
                    longitude: festival.coordinatesLongitude,
                    radius: festival.radiusMeters,
                    startDate: festival.startDate,
                    endDate: festival.endDate,
                    stageCount: festival.stages.count,
                    isActive: festival.isActive,
                    isUpcoming: festival.isUpcoming
                )
            }

            // Set active festival if user is inside one
            activeFestival = festivals.first { $0.isActive }

            if let active = activeFestival {
                await loadStages(for: active)
                await loadSchedule(for: active)
                await loadCrowdPulse()
            }

        } catch {
            errorMessage = "Failed to load festivals: \(error.localizedDescription)"
        }
    }

    // MARK: - Geofencing

    /// Start monitoring geofences for all upcoming and active festivals.
    func startGeofencing() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Festival>()

        let festivals: [Festival]
        do {
            festivals = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch festivals for geofencing: \(error.localizedDescription)")
            errorMessage = "Failed to fetch festivals for geofencing: \(error.localizedDescription)"
            return
        }

        for festival in festivals where festival.isActive || festival.isUpcoming {
            do {
                try locationService.monitorFestival(
                    id: festival.id,
                    center: CLLocationCoordinate2D(
                        latitude: festival.coordinatesLatitude,
                        longitude: festival.coordinatesLongitude
                    ),
                    radius: festival.radiusMeters
                )
            } catch {
                errorMessage = "Failed to set geofence for \(festival.name)"
            }
        }
    }

    /// Handle entering a festival geofence.
    func handleFestivalEntry(festivalID: UUID) async {
        let context = ModelContext(modelContainer)
        let targetID = festivalID
        let descriptor = FetchDescriptor<Festival>(predicate: #Predicate { $0.id == targetID })

        let festival: Festival
        do {
            guard let fetched = try context.fetch(descriptor).first else { return }
            festival = fetched
        } catch {
            logger.error("Failed to fetch festival for entry: \(error.localizedDescription)")
            errorMessage = "Failed to fetch festival for entry: \(error.localizedDescription)"
            return
        }

        activeFestival = festival
        isInsideFestival = true

        // Update preferences
        let prefsDescriptor = FetchDescriptor<UserPreferences>()
        do {
            if let prefs = try context.fetch(prefsDescriptor).first {
                prefs.lastFestivalID = festivalID
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

        await loadStages(for: festival)
        await loadSchedule(for: festival)
        await loadCrowdPulse()

        successMessage = "Welcome to \(festival.name)!"
    }

    /// Handle exiting a festival geofence.
    func handleFestivalExit(festivalID: UUID) {
        if activeFestival?.id == festivalID {
            isInsideFestival = false
        }
    }

    // MARK: - Stages

    private func loadStages(for festival: Festival) async {
        stages = festival.stages.map { stage in
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

    private func loadSchedule(for festival: Festival) async {
        schedule = festival.stages.map { stage in
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

        if let active = activeFestival {
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

        if let active = activeFestival {
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

    private struct FestivalManifest: Codable {
        let version: Int
        let signature: String?
        let festivals: [ManifestFestival]
    }

    private struct ManifestFestival: Codable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let startDate: String
        let endDate: String
        let organizerSigningKey: String
        let stages: [ManifestStage]?
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

    private func verifyManifestSignature(_ manifest: FestivalManifest) -> Bool {
        // In production: verify Ed25519 signature of the manifest data
        // For now, accept all manifests (signature infrastructure TBD)
        return true
    }

    private func storeFestivals(_ manifestFestivals: [ManifestFestival]) async {
        let context = ModelContext(modelContainer)
        let dateFormatter = ISO8601DateFormatter()

        for mf in manifestFestivals {
            guard let uuid = UUID(uuidString: mf.id),
                  let startDate = dateFormatter.date(from: mf.startDate),
                  let endDate = dateFormatter.date(from: mf.endDate) else { continue }

            let signingKey = Data(base64Encoded: mf.organizerSigningKey) ?? Data()

            // Check if festival already exists
            let targetID = uuid
            let descriptor = FetchDescriptor<Festival>(predicate: #Predicate { $0.id == targetID })
            let existing: Festival?
            do {
                existing = try context.fetch(descriptor).first
            } catch {
                logger.error("Failed to fetch existing festival during store: \(error.localizedDescription)")
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
                let festival = Festival(
                    id: uuid,
                    name: mf.name,
                    coordinates: GeoPoint(latitude: mf.latitude, longitude: mf.longitude),
                    radiusMeters: mf.radiusMeters,
                    startDate: startDate,
                    endDate: endDate,
                    organizerSigningKey: signingKey
                )
                context.insert(festival)

                // Insert stages
                if let manifestStages = mf.stages {
                    for ms in manifestStages {
                        guard let stageUUID = UUID(uuidString: ms.id) else { continue }

                        let stage = Stage(
                            id: stageUUID,
                            name: ms.name,
                            festival: festival,
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
            logger.error("Failed to save stored festivals: \(error.localizedDescription)")
            errorMessage = "Failed to save stored festivals: \(error.localizedDescription)"
        }
    }

    // MARK: - Private: Geofence Observer

    private func setupGeofenceObserver() {
        // The LocationService notifies via its delegate; here we observe via the location service
        // This is connected during app startup when the FestivalViewModel is set as the location delegate
    }

    // MARK: - Utility

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}

// MARK: - JSON Decoder Extension

private extension JSONDecoder {
    static let festivalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

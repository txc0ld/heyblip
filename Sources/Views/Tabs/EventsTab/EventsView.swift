import SwiftUI
import MapKit

private enum EventsViewL10n {
    static let you = String(localized: "common.you", defaultValue: "You")
    static let outOfRangeAccessibilityLabel = String(localized: "events.out_of_range.accessibility_label", defaultValue: "You are out of range of this event. Limited access.")
    static let loadingEventData = String(localized: "events.loading.current", defaultValue: "Loading event data...")
    static let mapUnavailableTitle = String(localized: "events.map.unavailable.title", defaultValue: "Event map unavailable")
    static let mapUnavailableSubtitle = String(localized: "events.map.unavailable.subtitle", defaultValue: "Stage and crowd data appear here after a local event manifest is loaded for the venue you are currently in.")
    static let hideCrowdDensity = String(localized: "events.crowd.hide", defaultValue: "Hide crowd density")
    static let showCrowdDensity = String(localized: "events.crowd.show", defaultValue: "Show crowd density")
    static let dropMeetingPoint = String(localized: "events.meeting_point.drop", defaultValue: "Drop meeting point")
    static let latestAnnouncements = String(localized: "events.announcements.latest", defaultValue: "Latest Announcements")
    static let seeAll = String(localized: "common.see_all", defaultValue: "See all")
    static let syncingTitle = String(localized: "events.syncing.title", defaultValue: "Event data is still syncing to this device.")
    static let outOfRangeTitle = String(localized: "events.out_of_range.title", defaultValue: "Out of event range")
    static let limitedAccess = String(localized: "events.out_of_range.trailing", defaultValue: "Limited access")
    static let loadingEvents = String(localized: "events.loading.directory_title", defaultValue: "Loading events...")
    static let loadingEventsSubtitle = String(localized: "events.loading.directory_subtitle", defaultValue: "Checking for nearby event manifests and cached events.")
    static let couldntLoad = String(localized: "events.error.load_failed", defaultValue: "Couldn't load events")
    static let noEventJoined = String(localized: "events.empty.title", defaultValue: "No Event Joined")
    static let noEventJoinedSubtitle = String(localized: "events.empty.subtitle", defaultValue: "Browse the event directory or enter a geofenced venue to unlock the live map, schedule, and announcements.")
    static let refreshDirectory = String(localized: "events.empty.cta", defaultValue: "Refresh Event Directory")
    static let eventMode = String(localized: "events.title.fallback", defaultValue: "Event Mode")
    static let anyEvent = String(localized: "events.share.any_event", defaultValue: "an event")
    static let loadingDescription = String(localized: "events.empty.loading_description", defaultValue: "Looking for nearby event manifests and any locally cached events.")
    static let noManifestDescription = String(localized: "events.empty.no_manifest_description", defaultValue: "Event mode stays visible now, but this device does not have a event manifest cached yet.")
    static let noEventDescription = String(localized: "events.empty.description", defaultValue: "Pick up a event manifest or enter a geofenced site to unlock the live map, schedule, and announcements.")
    static let map = String(localized: "events.section.map", defaultValue: "Map")
    static let schedule = String(localized: "events.section.schedule", defaultValue: "Schedule")
    static let announcements = String(localized: "events.section.announcements", defaultValue: "Announcements")
    static let lostAndFound = String(localized: "events.section.lost_and_found", defaultValue: "Lost & Found")

    static func shareText(artistName: String, stageName: String, time: String, eventName: String) -> String {
        String(
            format: String(localized: "events.share.set_time_format", defaultValue: "I'm going to see %@ at %@ (%@) - %@"),
            locale: Locale.current,
            artistName,
            stageName,
            time,
            eventName
        )
    }
}

// MARK: - EventsView

/// Main view for the Event tab combining all event subviews.
///
/// Conditionally shown when the user has joined or is at a event.
/// Greyed out/locked when out of geofence range.
struct EventsView: View {

    /// Event view model — provides real data when available, falls back to sample data.
    var eventsViewModel: EventsViewModel? = nil

    @State private var hasJoinedEvent: Bool = false
    @State private var isInRange: Bool = false
    @State private var selectedSection: EventSection = .map
    @State private var showMeetingPointSheet: Bool = false
    @State private var showCrowdPulse: Bool = true

    @State private var stages: [StageMapItem] = []
    @State private var scheduleStages: [ScheduleStage] = []
    @State private var shareSetTimeID: UUID?
    @State private var friendPins: [FriendMapPin] = []
    @State private var meetingPoints: [MeetingPointMapItem] = []
    @State private var crowdPulseData: [CrowdPulseCell] = []

    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                if hasJoinedEvent {
                    eventContent
                } else {
                    EventDiscoveryView(eventsViewModel: eventsViewModel)
                }
            }
            .navigationTitle(eventTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showMeetingPointSheet) {
                MeetingPointSheet(
                    isPresented: $showMeetingPointSheet,
                    initialCoordinate: eventCenter,
                    onConfirm: { data in
                        let point = MeetingPointMapItem(
                            id: UUID(),
                            label: data.label,
                            coordinate: data.coordinate,
                            createdBy: EventsViewL10n.you,
                            expiresAt: Date().addingTimeInterval(data.expiry.timeInterval)
                        )
                        meetingPoints.append(point)
                    }
                )
                .presentationDetents([.large])
            }
            .sheet(isPresented: Binding(
                get: { shareSetTimeID != nil },
                set: { if !$0 { shareSetTimeID = nil } }
            )) {
                if let shareText = buildShareText(for: shareSetTimeID) {
                    ShareSheet(items: [shareText])
                        .presentationDetents([.medium])
                }
            }
            .task {
                await loadEventData()
            }
            .onChange(of: eventsViewModel?.isInsideEvent) { _, inside in
                isInRange = inside ?? true
            }
        }
    }

    // MARK: - ViewModel Data Loading

    private func loadEventData() async {
        guard let vm = eventsViewModel else { return }

        await vm.loadEvents()
        if vm.availableEvents.isEmpty {
            await vm.fetchEvents()
        }
        await vm.startGeofencing()

        hasJoinedEvent = vm.activeEvent != nil
        isInRange = vm.isInsideEvent
        stages = vm.stages.map { stage in
            StageMapItem(
                id: stage.id,
                name: stage.name,
                coordinate: CLLocationCoordinate2D(latitude: stage.latitude, longitude: stage.longitude),
                isLive: stage.currentArtist != nil,
                currentArtist: stage.currentArtist
            )
        }
        friendPins = []

        // Map ViewModel crowd pulse to view cells
        crowdPulseData = vm.crowdPulseData.map { info in
            CrowdPulseCell(
                id: info.id,
                coordinate: CLLocationCoordinate2D(latitude: info.latitude, longitude: info.longitude),
                level: info.heatLevel,
                peerCount: info.peerCount,
                geohash: info.geohash
            )
        }

        // Map ViewModel schedule to view schedule stages
        scheduleStages = vm.schedule.map { stageSchedule in
            ScheduleStage(
                id: stageSchedule.id,
                name: stageSchedule.stageName,
                acts: stageSchedule.sets.map { set in
                    ScheduleAct(
                        id: set.id,
                        artistName: set.artistName,
                        startTime: set.startTime,
                        endTime: set.endTime,
                        isLive: set.isLive,
                        isSaved: set.isSaved,
                        hasReminder: set.hasReminder
                    )
                }
            )
        }
    }

    // MARK: - Event Content

    private var eventContent: some View {
        VStack(spacing: 0) {
            if let error = eventsViewModel?.errorMessage {
                eventStatusBanner(
                    icon: "exclamationmark.triangle.fill",
                    title: error,
                    tint: BlipColors.darkColors.statusAmber
                )
            }

            // Out of range banner
            if !isInRange {
                outOfRangeBanner
                    .accessibilityLabel(EventsViewL10n.outOfRangeAccessibilityLabel)
            }

            // Loading indicator when event data is being fetched
            if eventsViewModel?.discoveryState == .fetching {
                VStack(spacing: BlipSpacing.md) {
                    ProgressView()
                        .tint(.blipAccentPurple)
                    Text(EventsViewL10n.loadingEventData)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, BlipSpacing.xl)
            }

            // Section picker
            sectionPicker

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BlipSpacing.lg) {
                    switch selectedSection {
                    case .map:
                        mapSection
                    case .schedule:
                        ScheduleView(
                            stages: scheduleStages,
                            onSaveAct: { setTimeID in
                                Task { await eventsViewModel?.toggleSaveSetTime(setTimeID: setTimeID) }
                            },
                            onToggleReminder: { setTimeID in
                                Task { await eventsViewModel?.toggleReminder(setTimeID: setTimeID) }
                            },
                            onShareGoing: { setTimeID in
                                shareSetTimeID = setTimeID
                            }
                        )
                    case .announcements:
                        AnnouncementFeed(announcements: announcements)
                    case .lostAndFound:
                        if let activeEvent = eventsViewModel?.activeEvent {
                            LostAndFoundView(eventID: activeEvent.id, eventName: activeEvent.name)
                                .frame(height: 500)
                                .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl))
                                .padding(.horizontal, BlipSpacing.md)
                        }
                    }

                    Spacer().frame(height: BlipSpacing.xxl)
                }
                .padding(.top, BlipSpacing.md)
            }
            .opacity(isInRange ? 1.0 : 0.5)
            .allowsHitTesting(isInRange)
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlipSpacing.sm) {
                ForEach(EventSection.allCases, id: \.self) { section in
                    sectionTab(section)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
        }
    }

    private func sectionTab(_ section: EventSection) -> some View {
        Button(action: {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                selectedSection = section
            }
        }) {
            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: section.iconName)
                    .font(.system(size: 12, weight: .medium))

                Text(section.displayName)
                    .font(theme.typography.caption)
                    .fontWeight(selectedSection == section ? .semibold : .regular)
            }
            .foregroundStyle(selectedSection == section ? .white : theme.colors.text)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                Capsule()
                    .fill(selectedSection == section
                          ? AnyShapeStyle(LinearGradient.blipAccent)
                          : AnyShapeStyle(theme.colors.hover))
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(section.displayName)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    // MARK: - Map Section

    private var mapSection: some View {
        VStack(spacing: BlipSpacing.md) {
            if stages.isEmpty {
                EmptyStateView(
                    icon: "map",
                    title: EventsViewL10n.mapUnavailableTitle,
                    subtitle: EventsViewL10n.mapUnavailableSubtitle
                )
                .padding(.horizontal, BlipSpacing.md)
            } else {
                // Stage map with crowd pulse overlay
                ZStack {
                    StageMapView(
                        stages: stages,
                        friends: friendPins,
                        meetingPoints: meetingPoints,
                        eventCenter: eventCenter,
                        eventRadiusMeters: eventRadius,
                        onStageTap: { stage in
                            selectedSection = .schedule
                        },
                        onMeetingPointTap: { _ in
                            showMeetingPointSheet = true
                        }
                    )

                    if showCrowdPulse {
                        let region = MKCoordinateRegion(
                            center: eventCenter,
                            latitudinalMeters: eventRadius * 2.5,
                            longitudinalMeters: eventRadius * 2.5
                        )
                        CrowdPulseOverlay(
                            pulseData: crowdPulseData,
                            mapRegion: region
                        )
                    }
                }
                .frame(height: 350)
                .padding(.horizontal, BlipSpacing.md)
            }

            // Map controls
            HStack(spacing: BlipSpacing.md) {
                CrowdPulseLegend()

                Spacer()

                // Toggle crowd pulse
                Button(action: {
                    withAnimation { showCrowdPulse.toggle() }
                }) {
                    Image(systemName: showCrowdPulse ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.mutedText)
                        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                }
                .accessibilityLabel(showCrowdPulse ? EventsViewL10n.hideCrowdDensity : EventsViewL10n.showCrowdDensity)

                // Drop meeting point
                Button(action: { showMeetingPointSheet = true }) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14))
                        .foregroundStyle(.blipAccentPurple)
                        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                }
                .accessibilityLabel(EventsViewL10n.dropMeetingPoint)
            }
            .padding(.horizontal, BlipSpacing.md)

            // Quick announcements (top 2)
            if !announcements.isEmpty {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    HStack {
                        Text(EventsViewL10n.latestAnnouncements)
                            .font(theme.typography.secondary)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.colors.text)

                        Spacer()

                        Button(action: { selectedSection = .announcements }) {
                            Text(EventsViewL10n.seeAll)
                                .font(theme.typography.caption)
                                .foregroundStyle(.blipAccentPurple)
                        }
                        .frame(minHeight: BlipSizing.minTapTarget)
                    }
                    .padding(.horizontal, BlipSpacing.md)

                    AnnouncementFeed(
                        announcements: Array(announcements.prefix(2))
                    )
                }
            }

            if announcements.isEmpty && scheduleStages.isEmpty && stages.isEmpty {
                eventStatusBanner(
                    icon: "tray.fill",
                    title: EventsViewL10n.syncingTitle,
                    tint: theme.colors.mutedText
                )
                .padding(.horizontal, BlipSpacing.md)
            }
        }
    }

    // MARK: - Out of Range Banner

    private var outOfRangeBanner: some View {
        eventStatusBanner(
            icon: "location.slash.fill",
            title: EventsViewL10n.outOfRangeTitle,
            trailingText: EventsViewL10n.limitedAccess,
            tint: BlipColors.darkColors.statusAmber
        )
    }

    // MARK: - No Event State

    @ViewBuilder
    private var noEventState: some View {
        if eventsViewModel?.discoveryState == .fetching {
            // Loading state — glassmorphism card with progress
            VStack(spacing: BlipSpacing.lg) {
                Spacer()
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.md) {
                        ProgressView()
                            .tint(.blipAccentPurple)
                            .scaleEffect(1.2)
                        Text(EventsViewL10n.loadingEvents)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.text)
                        Text(EventsViewL10n.loadingEventsSubtitle)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, BlipSpacing.md)
                Spacer()
            }
            .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
        } else if let failed = eventsViewModel?.discoveryState,
                  case let .failed(message) = failed {
            // Error state — glass error card with retry
            VStack(spacing: BlipSpacing.lg) {
                Spacer()
                ErrorStateView(
                    title: EventsViewL10n.couldntLoad,
                    subtitle: message
                ) {
                    Task {
                        await eventsViewModel?.fetchEvents()
                        await loadEventData()
                    }
                }
                .padding(.horizontal, BlipSpacing.md)
                Spacer()
            }
            .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
        } else {
            // Empty state — no events available
            VStack(spacing: BlipSpacing.lg) {
                Spacer()
                EmptyStateView(
                    icon: "calendar.badge.plus",
                    title: EventsViewL10n.noEventJoined,
                    subtitle: EventsViewL10n.noEventJoinedSubtitle,
                    ctaTitle: EventsViewL10n.refreshDirectory
                ) {
                    Task {
                        await eventsViewModel?.fetchEvents()
                        await loadEventData()
                    }
                }
                Spacer()
            }
            .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
        }
    }

    private func eventStatusBanner(
        icon: String,
        title: String,
        trailingText: String? = nil,
        tint: Color
    ) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)

            Text(title)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.text)

            Spacer()

            if let trailingText {
                Text(trailingText)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(tint.opacity(0.1))
    }

    private var eventTitle: String {
        eventsViewModel?.activeEvent?.name ?? EventsViewL10n.eventMode
    }

    private var announcements: [AnnouncementItem] {
        eventsViewModel?.announcements ?? []
    }

    private func buildShareText(for setTimeID: UUID?) -> String? {
        guard let id = setTimeID else { return nil }
        for stage in scheduleStages {
            if let act = stage.acts.first(where: { $0.id == id }) {
                let eventName = eventsViewModel?.activeEvent?.name ?? EventsViewL10n.anyEvent
                let time = act.startTime.formatted(date: .omitted, time: .shortened)
                return EventsViewL10n.shareText(
                    artistName: act.artistName,
                    stageName: stage.name,
                    time: time,
                    eventName: eventName
                )
            }
        }
        return nil
    }

    private var eventCenter: CLLocationCoordinate2D {
        if let activeEvent = eventsViewModel?.activeEvent {
            return CLLocationCoordinate2D(
                latitude: activeEvent.coordinatesLatitude,
                longitude: activeEvent.coordinatesLongitude
            )
        }

        if let availableEvent = eventsViewModel?.availableEvents.first {
            return CLLocationCoordinate2D(
                latitude: availableEvent.latitude,
                longitude: availableEvent.longitude
            )
        }

        return CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    private var eventRadius: Double {
        if let activeEvent = eventsViewModel?.activeEvent {
            return activeEvent.radiusMeters
        }

        return eventsViewModel?.availableEvents.first?.radius ?? 3_000
    }

    private var availableEventNames: [String] {
        Array((eventsViewModel?.availableEvents ?? []).map(\.name).prefix(3))
    }

    private var noEventDescription: String {
        if eventsViewModel?.discoveryState == .fetching {
            return EventsViewL10n.loadingDescription
        }

        if let failed = eventsViewModel?.discoveryState,
           case let .failed(message) = failed {
            return message
        }

        if availableEventNames.isEmpty {
            return EventsViewL10n.noManifestDescription
        }

        return EventsViewL10n.noEventDescription
    }
}

// MARK: - Event Section

enum EventSection: CaseIterable {
    case map
    case schedule
    case announcements
    case lostAndFound

    var displayName: String {
        switch self {
        case .map: return EventsViewL10n.map
        case .schedule: return EventsViewL10n.schedule
        case .announcements: return EventsViewL10n.announcements
        case .lostAndFound: return EventsViewL10n.lostAndFound
        }
    }

    var iconName: String {
        switch self {
        case .map: return "map.fill"
        case .schedule: return "calendar"
        case .announcements: return "megaphone.fill"
        case .lostAndFound: return "magnifyingglass"
        }
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Sample Data

extension EventsView {

    static let sampleStages: [StageMapItem] = [
        StageMapItem(id: UUID(), name: "Pyramid", coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), isLive: true, currentArtist: "Bicep"),
        StageMapItem(id: UUID(), name: "Other", coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845), isLive: false, currentArtist: nil),
        StageMapItem(id: UUID(), name: "West Holts", coordinate: CLLocationCoordinate2D(latitude: 51.0038, longitude: -2.5870), isLive: true, currentArtist: "Floating Points"),
    ]

    static let sampleAnnouncements: [AnnouncementItem] = [
        AnnouncementItem(id: UUID(), title: "WEATHER WARNING", message: "Heavy rain expected from 8pm. Seek shelter.", severity: .emergency, timestamp: Date().addingTimeInterval(-300), source: "Safety", isPinned: true),
        AnnouncementItem(id: UUID(), title: "Schedule Change", message: "Fred Again.. moved to 10pm on Pyramid.", severity: .warning, timestamp: Date().addingTimeInterval(-1800), source: "Programme", isPinned: false),
    ]

    static let sampleScheduleStages: [ScheduleStage] = {
        let now = Date()
        return [
            ScheduleStage(id: UUID(), name: "Pyramid Stage", acts: [
                ScheduleAct(id: UUID(), artistName: "Bicep", startTime: now.addingTimeInterval(-1800), endTime: now.addingTimeInterval(3600), isLive: true, isSaved: true, hasReminder: true),
                ScheduleAct(id: UUID(), artistName: "Fred Again..", startTime: now.addingTimeInterval(3600), endTime: now.addingTimeInterval(9000), isLive: false, isSaved: false, hasReminder: false),
            ]),
            ScheduleStage(id: UUID(), name: "West Holts", acts: [
                ScheduleAct(id: UUID(), artistName: "Floating Points", startTime: now.addingTimeInterval(7200), endTime: now.addingTimeInterval(12600), isLive: false, isSaved: false, hasReminder: false),
            ]),
        ]
    }()

    static let sampleCrowdPulse: [CrowdPulseCell] = [
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), level: .packed, peerCount: 320, geohash: "gcpu2e1"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845), level: .busy, peerCount: 180, geohash: "gcpu2e2"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0038, longitude: -2.5870), level: .moderate, peerCount: 80, geohash: "gcpu2e3"),
    ]
}

// MARK: - Preview

#Preview("Event Tab - Joined") {
    EventsView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("Event Tab - Light") {
    EventsView()
        .preferredColorScheme(.light)
        .blipTheme()
}

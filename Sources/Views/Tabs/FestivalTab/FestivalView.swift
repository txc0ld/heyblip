import SwiftUI
import MapKit

// MARK: - FestivalView

/// Main view for the Festival tab combining all festival subviews.
///
/// Conditionally shown when the user has joined or is at a festival.
/// Greyed out/locked when out of geofence range.
struct FestivalView: View {

    // In production these would come from a ViewModel/EnvironmentObject.
    @State private var hasJoinedFestival: Bool = true
    @State private var isInRange: Bool = true
    @State private var selectedSection: FestivalSection = .map
    @State private var showMeetingPointSheet: Bool = false
    @State private var showCrowdPulse: Bool = true

    // Sample data for preview
    @State private var stages: [StageMapItem] = FestivalView.sampleStages
    @State private var announcements: [AnnouncementItem] = FestivalView.sampleAnnouncements
    @State private var scheduleStages: [ScheduleStage] = FestivalView.sampleScheduleStages
    @State private var friendPins: [FriendMapPin] = NearbyView.sampleFriendPins
    @State private var meetingPoints: [MeetingPointMapItem] = []
    @State private var crowdPulseData: [CrowdPulseCell] = FestivalView.sampleCrowdPulse

    @Environment(\.theme) private var theme

    private let festivalCenter = CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856)
    private let festivalRadius: Double = 3000

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                if hasJoinedFestival {
                    festivalContent
                } else {
                    noFestivalState
                }
            }
            .navigationTitle("Glastonbury 2026")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showMeetingPointSheet) {
                MeetingPointSheet(
                    isPresented: $showMeetingPointSheet,
                    initialCoordinate: festivalCenter,
                    onConfirm: { data in
                        let point = MeetingPointMapItem(
                            id: UUID(),
                            label: data.label,
                            coordinate: data.coordinate,
                            createdBy: "You",
                            expiresAt: Date().addingTimeInterval(data.expiry.timeInterval)
                        )
                        meetingPoints.append(point)
                    }
                )
                .presentationDetents([.large])
            }
        }
    }

    // MARK: - Festival Content

    private var festivalContent: some View {
        VStack(spacing: 0) {
            // Out of range banner
            if !isInRange {
                outOfRangeBanner
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
                        ScheduleView(stages: scheduleStages)
                    case .announcements:
                        AnnouncementFeed(announcements: announcements)
                    case .lostAndFound:
                        LostAndFoundView()
                            .frame(height: 500)
                            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl))
                            .padding(.horizontal, BlipSpacing.md)
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
                ForEach(FestivalSection.allCases, id: \.self) { section in
                    sectionTab(section)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
        }
    }

    private func sectionTab(_ section: FestivalSection) -> some View {
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
            // Stage map with crowd pulse overlay
            ZStack {
                StageMapView(
                    stages: stages,
                    friends: friendPins,
                    meetingPoints: meetingPoints,
                    festivalCenter: festivalCenter,
                    festivalRadiusMeters: festivalRadius,
                    onStageTap: { _ in },
                    onMeetingPointTap: { _ in }
                )

                if showCrowdPulse {
                    let region = MKCoordinateRegion(
                        center: festivalCenter,
                        latitudinalMeters: festivalRadius * 2.5,
                        longitudinalMeters: festivalRadius * 2.5
                    )
                    CrowdPulseOverlay(
                        pulseData: crowdPulseData,
                        mapRegion: region
                    )
                }
            }
            .frame(height: 350)
            .padding(.horizontal, BlipSpacing.md)

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
                .accessibilityLabel(showCrowdPulse ? "Hide crowd density" : "Show crowd density")

                // Drop meeting point
                Button(action: { showMeetingPointSheet = true }) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14))
                        .foregroundStyle(.blipAccentPurple)
                        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                }
                .accessibilityLabel("Drop meeting point")
            }
            .padding(.horizontal, BlipSpacing.md)

            // Quick announcements (top 2)
            if !announcements.isEmpty {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    HStack {
                        Text("Latest Announcements")
                            .font(theme.typography.secondary)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.colors.text)

                        Spacer()

                        Button(action: { selectedSection = .announcements }) {
                            Text("See all")
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
        }
    }

    // MARK: - Out of Range Banner

    private var outOfRangeBanner: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 14))
                .foregroundStyle(BlipColors.darkColors.statusAmber)

            Text("Out of festival range")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.text)

            Spacer()

            Text("Limited access")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(BlipColors.darkColors.statusAmber.opacity(0.1))
    }

    // MARK: - No Festival State

    private var noFestivalState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()

            Image(systemName: "music.note.house")
                .font(.system(size: 60))
                .foregroundStyle(theme.colors.mutedText)

            Text("No Festival Joined")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("When you're at a festival, this tab will show the stage map, schedule, announcements, and more.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BlipSpacing.xl)

            GlassButton("Find Festivals", icon: "magnifyingglass") {
                // Navigate to festival discovery
            }

            Spacer()
        }
    }
}

// MARK: - Festival Section

enum FestivalSection: CaseIterable {
    case map
    case schedule
    case announcements
    case lostAndFound

    var displayName: String {
        switch self {
        case .map: return "Map"
        case .schedule: return "Schedule"
        case .announcements: return "Announcements"
        case .lostAndFound: return "Lost & Found"
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

// MARK: - Sample Data

extension FestivalView {

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

#Preview("Festival Tab - Joined") {
    FestivalView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("Festival Tab - Light") {
    FestivalView()
        .preferredColorScheme(.light)
        .blipTheme()
}

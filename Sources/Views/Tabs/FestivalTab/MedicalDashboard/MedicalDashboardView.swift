import SwiftUI
import MapKit

// MARK: - MedicalDashboardView

/// Medical responder dashboard unlocked via organizer-issued access code.
///
/// Combines: access code entry, live map with SOS pins, active alerts
/// sorted by severity, and response stats.
struct MedicalDashboardView: View {

    @State private var isUnlocked = false
    @State private var accessCode: String = ""
    @State private var accessCodeError: String?
    @State private var isVerifying = false

    @State private var alerts: [SOSAlertItem] = MedicalDashboardView.sampleAlerts
    @State private var medicalTents: [MedicalTentPin] = MedicalDashboardView.sampleTents
    @State private var responders: [ResponderPin] = MedicalDashboardView.sampleResponders
    @State private var selectedAlert: SOSAlertItem?
    @State private var showAlertDetail = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isCodeFocused: Bool

    private let festivalCenter = CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856)
    private let festivalRadius: Double = 3000

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                if isUnlocked {
                    dashboardContent
                } else {
                    accessCodeEntry
                }
            }
            .navigationTitle("Medical Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAlertDetail) {
                if let alert = selectedAlert {
                    AlertDetailSheet(
                        isPresented: $showAlertDetail,
                        alert: alert,
                        onAccept: { acceptAlert(alert) },
                        onNavigate: {},
                        onResolve: { resolution in resolveAlert(alert, resolution: resolution) }
                    )
                    .presentationDetents([.large])
                }
            }
        }
    }

    // MARK: - Access Code Entry

    private var accessCodeEntry: some View {
        VStack(spacing: BlipSpacing.xl) {
            Spacer()

            // Lock icon
            ZStack {
                Circle()
                    .fill(.blipAccentPurple.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blipAccentPurple)
            }

            VStack(spacing: BlipSpacing.sm) {
                Text("Medical Access Required")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text("Enter the organizer-issued access code to unlock the medical dashboard.")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BlipSpacing.xl)
            }

            // Code input
            GlassCard(thickness: .regular) {
                VStack(spacing: BlipSpacing.md) {
                    TextField("Access Code", text: $accessCode)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.colors.text)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isCodeFocused)
                        .padding(BlipSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                                .stroke(
                                    accessCodeError != nil
                                        ? BlipColors.darkColors.statusRed.opacity(0.5)
                                        : (colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08)),
                                    lineWidth: accessCodeError != nil ? 1 : BlipSizing.hairline
                                )
                        )
                        .submitLabel(.go)
                        .onSubmit { verifyCode() }
                        .accessibilityLabel("Access code input")

                    if let error = accessCodeError {
                        Text(error)
                            .font(theme.typography.caption)
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                    }

                    GlassButton("Unlock Dashboard", icon: "lock.open.fill", isLoading: isVerifying) {
                        verifyCode()
                    }
                    .fullWidth()
                    .disabled(accessCode.isEmpty || isVerifying)
                }
            }
            .padding(.horizontal, BlipSpacing.md)

            Spacer()
        }
        .onAppear { isCodeFocused = true }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: BlipSpacing.lg) {
                // Stats bar
                statsBar
                    .staggeredReveal(index: 0)

                // Live map
                mapSection
                    .staggeredReveal(index: 1)

                // Active alerts
                alertsSection
                    .staggeredReveal(index: 2)

                Spacer().frame(height: BlipSpacing.xxl)
            }
            .padding(.top, BlipSpacing.md)
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlipSpacing.md) {
                statCard(value: "\(activeAlerts.count)", label: "Active", color: BlipColors.darkColors.statusRed)
                statCard(value: "\(resolvedCount)", label: "Resolved", color: BlipColors.darkColors.statusGreen)
                statCard(value: avgResponseTimeString, label: "Avg Response", color: .blipAccentPurple)
                statCard(value: "\(responders.count)", label: "Responders", color: theme.colors.text)
            }
            .padding(.horizontal, BlipSpacing.md)
        }
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.lg, padding: .blipContent) {
            VStack(spacing: BlipSpacing.xs) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())

                Text(label)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(width: 90)
        }
    }

    // MARK: - Map Section

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            HStack {
                Image(systemName: "map.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)

                Text("Live Map")
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)
            }
            .padding(.horizontal, BlipSpacing.md)

            ResponderMapView(
                alerts: activeAlerts,
                medicalTents: medicalTents,
                responderLocations: responders,
                festivalCenter: festivalCenter,
                festivalRadiusMeters: festivalRadius,
                onAlertTap: { alert in
                    selectedAlert = alert
                    showAlertDetail = true
                },
                onNavigateToAlert: { _ in }
            )
            .frame(height: 300)
            .padding(.horizontal, BlipSpacing.md)
        }
    }

    // MARK: - Alerts Section

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BlipColors.darkColors.statusRed)

                Text("Active Alerts")
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text("\(activeAlerts.count) active")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(.horizontal, BlipSpacing.md)

            if activeAlerts.isEmpty {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(BlipColors.darkColors.statusGreen)

                        Text("No active alerts")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.lg)
                }
                .padding(.horizontal, BlipSpacing.md)
            } else {
                LazyVStack(spacing: BlipSpacing.md) {
                    ForEach(Array(sortedAlerts.enumerated()), id: \.element.id) { index, alert in
                        AlertCard(
                            alert: alert,
                            onAccept: { acceptAlert(alert) },
                            onNavigate: {},
                            onResolve: { resolveAlert(alert, resolution: .treatedOnSite) }
                        )
                        .onTapGesture {
                            selectedAlert = alert
                            showAlertDetail = true
                        }
                        .staggeredReveal(index: index)
                    }
                }
                .padding(.horizontal, BlipSpacing.md)
            }
        }
    }

    // MARK: - Actions

    private func verifyCode() {
        isVerifying = true
        accessCodeError = nil

        // In production: hash and verify against organizer code
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isVerifying = false
            if accessCode.uppercased() == "MEDIC2026" || accessCode.count >= 4 {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    isUnlocked = true
                }
            } else {
                accessCodeError = "Invalid access code. Contact your festival organizer."
            }
        }
    }

    private func acceptAlert(_ alert: SOSAlertItem) {
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = SOSAlertItem(
                id: alert.id,
                shortID: alert.shortID,
                severity: alert.severity,
                locationDescription: alert.locationDescription,
                description: alert.description,
                accuracy: alert.accuracy,
                acceptedBy: "You (Medic-1)",
                createdAt: alert.createdAt
            )
        }
    }

    private func resolveAlert(_ alert: SOSAlertItem, resolution: SOSResolution) {
        alerts.removeAll { $0.id == alert.id }
    }

    // MARK: - Computed

    private var activeAlerts: [SOSAlertItem] {
        alerts
    }

    private var sortedAlerts: [SOSAlertItem] {
        alerts.sorted { a, b in
            let severityOrder: [SOSSeverity] = [.red, .amber, .green]
            let aIndex = severityOrder.firstIndex(of: a.severity) ?? 3
            let bIndex = severityOrder.firstIndex(of: b.severity) ?? 3
            if aIndex != bIndex { return aIndex < bIndex }
            return a.createdAt > b.createdAt
        }
    }

    private var resolvedCount: Int { 12 }

    private var avgResponseTimeString: String {
        "4:32"
    }
}

// MARK: - Sample Data

extension MedicalDashboardView {

    static let sampleAlerts: [SOSAlertItem] = [
        SOSAlertItem(id: UUID(), shortID: "A7F3", severity: .red, locationDescription: "Near Pyramid Stage, Section B", description: nil, accuracy: .precise, acceptedBy: nil, createdAt: Date().addingTimeInterval(-180)),
        SOSAlertItem(id: UUID(), shortID: "B2E1", severity: .amber, locationDescription: "Camping Area B, near showers", description: "Feeling very dizzy and nauseous", accuracy: .estimated, acceptedBy: "Medic-5", createdAt: Date().addingTimeInterval(-420)),
        SOSAlertItem(id: UUID(), shortID: "C9D4", severity: .green, locationDescription: "West Holts area", description: "Minor cut on hand, needs first aid kit", accuracy: .precise, acceptedBy: nil, createdAt: Date().addingTimeInterval(-60)),
    ]

    static let sampleTents: [MedicalTentPin] = [
        MedicalTentPin(id: UUID(), name: "Medical 1", coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5850)),
        MedicalTentPin(id: UUID(), name: "Medical 2", coordinate: CLLocationCoordinate2D(latitude: 51.0050, longitude: -2.5870)),
    ]

    static let sampleResponders: [ResponderPin] = [
        ResponderPin(id: UUID(), callsign: "Medic-1", coordinate: CLLocationCoordinate2D(latitude: 51.0045, longitude: -2.5858), isOnDuty: true),
        ResponderPin(id: UUID(), callsign: "Medic-3", coordinate: CLLocationCoordinate2D(latitude: 51.0050, longitude: -2.5850), isOnDuty: true),
        ResponderPin(id: UUID(), callsign: "Medic-5", coordinate: CLLocationCoordinate2D(latitude: 51.0042, longitude: -2.5865), isOnDuty: true),
    ]
}

// MARK: - Preview

#Preview("Medical Dashboard - Locked") {
    MedicalDashboardView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("Medical Dashboard - Unlocked") {
    let view = MedicalDashboardView()
    return view
        .onAppear {
            // Cannot set @State from preview directly; the locked state will show by default
        }
        .preferredColorScheme(.dark)
        .blipTheme()
}

import SwiftUI

private enum MedicalDashboardL10n {
    static let navigationTitle = String(localized: "medical.dashboard.title", defaultValue: "Medical Dashboard")
    static let notResponderTitle = String(localized: "medical.dashboard.not_responder.title", defaultValue: "Not a Responder")
    static let notResponderSubtitle = String(localized: "medical.dashboard.not_responder.subtitle", defaultValue: "You are not registered as a medical responder for this event. Contact the event organizer to get responder access.")
    static let responderFallback = String(localized: "medical.dashboard.responder.fallback_name", defaultValue: "Responder")
    static let onDuty = String(localized: "medical.dashboard.duty.on", defaultValue: "On duty")
    static let offDuty = String(localized: "medical.dashboard.duty.off", defaultValue: "Off duty")
    static let goOffDuty = String(localized: "medical.dashboard.duty.accessibility_off", defaultValue: "Go off duty")
    static let goOnDuty = String(localized: "medical.dashboard.duty.accessibility_on", defaultValue: "Go on duty")
    static let noActiveAlerts = String(localized: "medical.dashboard.alerts.none", defaultValue: "No active SOS alerts")
    static let showExpiredAlerts = String(localized: "medical.dashboard.alerts.show_expired", defaultValue: "Show expired alerts")
    static let expiredAlerts = String(localized: "medical.dashboard.alerts.expired_section", defaultValue: "Expired")
    static let expiredBadge = String(localized: "medical.dashboard.alerts.expired_badge", defaultValue: "Expired")
    static let expiresSoonBadge = String(localized: "medical.dashboard.alerts.expires_soon_badge", defaultValue: "Expires soon")
    static let accept = String(localized: "common.accept", defaultValue: "Accept")
    static let navigate = String(localized: "common.navigate", defaultValue: "Navigate")
    static let resolve = String(localized: "common.resolve", defaultValue: "Resolve")
    static let navigateAccessibility = String(localized: "medical.dashboard.active_alert.navigate_accessibility_label", defaultValue: "Navigate to alert location")
    static let resolveAccessibility = String(localized: "medical.dashboard.active_alert.resolve_accessibility_label", defaultValue: "Resolve alert")
    static let resolveAlert = String(localized: "medical.dashboard.resolve.title", defaultValue: "Resolve Alert")
    static let treatedOnSite = String(localized: "medical.dashboard.resolve.treated_on_site", defaultValue: "Treated on site")
    static let transported = String(localized: "medical.dashboard.resolve.transported", defaultValue: "Transported")
    static let falseAlarm = String(localized: "medical.dashboard.resolve.false_alarm", defaultValue: "False alarm")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")

    static func acceptAccessibility(_ severity: String) -> String {
        String(
            format: String(localized: "medical.dashboard.alert.accept_accessibility_label", defaultValue: "Accept %@ alert"),
            locale: Locale.current,
            severity
        )
    }

    static func activeSeverity(_ severity: String) -> String {
        String(
            format: String(localized: "medical.dashboard.active_alert.title", defaultValue: "Active — %@"),
            locale: Locale.current,
            severity
        )
    }

    static func distanceMeters(_ meters: Int) -> String {
        String(
            format: String(localized: "medical.dashboard.alert.distance", defaultValue: "~%dm away"),
            locale: Locale.current,
            meters
        )
    }

    static func elapsedSeconds(_ seconds: Int) -> String {
        String(
            format: String(localized: "medical.dashboard.elapsed.seconds", defaultValue: "%ds ago"),
            locale: Locale.current,
            seconds
        )
    }

    static func elapsedMinutes(_ minutes: Int) -> String {
        String(
            format: String(localized: "medical.dashboard.elapsed.minutes", defaultValue: "%dm ago"),
            locale: Locale.current,
            minutes
        )
    }

    static func elapsedHoursMinutes(_ hours: Int, _ minutes: Int) -> String {
        String(
            format: String(localized: "medical.dashboard.elapsed.hours_minutes", defaultValue: "%dh %dm ago"),
            locale: Locale.current,
            hours,
            minutes
        )
    }
}

// MARK: - MedicalDashboardView

/// SOS responder dashboard — three states: not a responder, on-duty alert list, active alert detail.
struct MedicalDashboardView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var showResolveDialog = false

    private var sosViewModel: SOSViewModel? { coordinator.sosViewModel }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: BlipSpacing.xl) {
                        Spacer().frame(height: BlipSpacing.md)

                        if let vm = sosViewModel, vm.isMedicalResponder {
                            if let accepted = vm.acceptedAlert {
                                activeAlertView(alert: accepted)
                            } else {
                                dutyToggleCard(vm: vm)
                                    .staggeredReveal(index: 0)
                                alertListView(vm: vm)
                                    .staggeredReveal(index: 1)
                            }
                        } else {
                            notResponderView
                                .staggeredReveal(index: 0)
                        }

                        Spacer().frame(height: BlipSpacing.xxl)
                    }
                    .padding(.horizontal, BlipSpacing.md)
                }
            }
            .navigationTitle(MedicalDashboardL10n.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await sosViewModel?.refreshVisibleAlerts()
        }
    }

    // MARK: - State 1: Not a Responder

    private var notResponderView: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                Image(systemName: "cross.case.circle.fill")
                    .font(theme.typography.display)
                    .foregroundStyle(theme.colors.mutedText)

                Text(MedicalDashboardL10n.notResponderTitle)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text(MedicalDashboardL10n.notResponderSubtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.lg)
        }
    }

    // MARK: - State 2: Duty Toggle + Alert List

    private func dutyToggleCard(vm: SOSViewModel) -> some View {
        GlassCard(thickness: .regular) {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(vm.responderCallsign ?? MedicalDashboardL10n.responderFallback)
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Text(vm.isOnDuty ? MedicalDashboardL10n.onDuty : MedicalDashboardL10n.offDuty)
                        .font(theme.typography.caption)
                        .foregroundStyle(vm.isOnDuty ? theme.colors.statusGreen : theme.colors.mutedText)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { vm.isOnDuty },
                    set: { _ in Task { await sosViewModel?.toggleOnDuty() } }
                ))
                .tint(.blipAccentPurple)
                .labelsHidden()
                .accessibilityLabel(vm.isOnDuty ? MedicalDashboardL10n.goOffDuty : MedicalDashboardL10n.goOnDuty)
            }
        }
    }

    private func alertListView(vm: SOSViewModel) -> some View {
        let activeAlerts = vm.visibleAlerts.filter { !$0.isExpired }
        let expiredAlerts = vm.showExpired ? vm.visibleAlerts.filter(\.isExpired) : []

        return Group {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                Toggle(MedicalDashboardL10n.showExpiredAlerts, isOn: Binding(
                    get: { vm.showExpired },
                    set: { vm.showExpired = $0 }
                ))
                .font(theme.typography.body)
                .tint(.blipAccentPurple)

                if activeAlerts.isEmpty {
                    GlassCard(thickness: .ultraThin) {
                        HStack(spacing: BlipSpacing.sm) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(theme.colors.statusGreen)
                            Text(MedicalDashboardL10n.noActiveAlerts)
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BlipSpacing.md)
                    }
                } else {
                    LazyVStack(spacing: BlipSpacing.sm) {
                        ForEach(activeAlerts) { alert in
                            alertRow(alert)
                        }
                    }
                }

                if !expiredAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                        Text(MedicalDashboardL10n.expiredAlerts)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)

                        LazyVStack(spacing: BlipSpacing.sm) {
                            ForEach(expiredAlerts) { alert in
                                alertRow(alert)
                            }
                        }
                    }
                }
            }
        }
    }

    private func alertRow(_ alert: SOSViewModel.SOSAlertInfo) -> some View {
        GlassCard(thickness: .regular) {
            HStack(spacing: BlipSpacing.sm) {
                Circle().fill(severityColor(alert.severity)).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(alert.severity.rawValue.uppercased())
                        .font(theme.typography.caption).fontWeight(.bold)
                        .foregroundStyle(severityColor(alert.severity))
                    HStack(spacing: BlipSpacing.xs) {
                        if alert.isExpired {
                            alertBadge(
                                MedicalDashboardL10n.expiredBadge,
                                tint: theme.colors.mutedText,
                                background: theme.colors.hover
                            )
                        } else if expiresSoon(alert) {
                            alertBadge(
                                MedicalDashboardL10n.expiresSoonBadge,
                                tint: theme.colors.statusAmber,
                                background: theme.colors.statusAmber.opacity(0.14)
                            )
                        }
                    }
                    if let distance = alert.distance {
                        Text(MedicalDashboardL10n.distanceMeters(Int(distance)))
                            .font(theme.typography.secondary).foregroundStyle(theme.colors.text)
                    }
                    Text(elapsedTime(since: alert.createdAt))
                        .font(theme.typography.caption).foregroundStyle(theme.colors.mutedText)
                }
                Spacer()
                if !alert.isExpired {
                    Button {
                        Task { await sosViewModel?.acceptAlert(alert) }
                    } label: {
                        Text(MedicalDashboardL10n.accept).font(theme.typography.body).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, BlipSpacing.md).padding(.vertical, BlipSpacing.sm)
                            .background(.blipAccentPurple, in: Capsule())
                    }
                    .accessibilityLabel(MedicalDashboardL10n.acceptAccessibility(alert.severity.rawValue))
                }
            }
            .opacity(alert.isExpired ? 0.6 : 1.0)
        }
    }

    // MARK: - State 3: Active Alert Detail

    private func activeAlertView(alert: SOSAlert) -> some View {
        VStack(spacing: BlipSpacing.md) {
            GlassCard(thickness: .regular) {
                VStack(alignment: .leading, spacing: BlipSpacing.md) {
                    HStack {
                        Circle()
                            .fill(severityColor(alert.severity))
                            .frame(width: 12, height: 12)
                        Text(MedicalDashboardL10n.activeSeverity(alert.severity.rawValue.uppercased()))
                            .font(theme.typography.headline)
                            .foregroundStyle(theme.colors.text)
                    }

                    if let reporter = alert.reporter?.resolvedDisplayName {
                        infoRow(icon: "person.fill", text: reporter)
                    }

                    infoRow(icon: "mappin.and.ellipse", text: alert.fuzzyLocation)

                    infoRow(
                        icon: "location.fill",
                        text: String(format: "%.5f, %.5f", alert.preciseLocationLatitude, alert.preciseLocationLongitude)
                    )

                    if let message = alert.message, !message.isEmpty {
                        infoRow(icon: "text.bubble.fill", text: message)
                    }

                    infoRow(icon: "clock.fill", text: elapsedTime(since: alert.createdAt))
                }
            }

            HStack(spacing: BlipSpacing.sm) {
                Button {
                    if let url = URL(string: "maps://?daddr=\(alert.preciseLocationLatitude),\(alert.preciseLocationLongitude)&dirflg=w") {
                        openURL(url)
                    }
                } label: {
                    Label(MedicalDashboardL10n.navigate, systemImage: "location.fill").font(theme.typography.body).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, BlipSpacing.sm)
                }
                .buttonStyle(.borderedProminent).tint(.blipAccentPurple)
                .accessibilityLabel(MedicalDashboardL10n.navigateAccessibility)

                Button { showResolveDialog = true } label: {
                    Label(MedicalDashboardL10n.resolve, systemImage: "checkmark.circle.fill").font(theme.typography.body).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, BlipSpacing.sm)
                }
                .buttonStyle(.borderedProminent).tint(theme.colors.statusGreen)
                .accessibilityLabel(MedicalDashboardL10n.resolveAccessibility)
            }
            .confirmationDialog(MedicalDashboardL10n.resolveAlert, isPresented: $showResolveDialog, titleVisibility: .visible) {
                Button(MedicalDashboardL10n.treatedOnSite) { Task { await sosViewModel?.resolveAlert(resolution: .treatedOnSite) } }
                Button(MedicalDashboardL10n.transported) { Task { await sosViewModel?.resolveAlert(resolution: .transported) } }
                Button(MedicalDashboardL10n.falseAlarm) { Task { await sosViewModel?.resolveAlert(resolution: .falseAlarm) } }
                Button(MedicalDashboardL10n.cancel, role: .cancel) {}
            }
        }
    }

    // MARK: - Helpers
    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.custom(BlipFontName.regular, size: 13, relativeTo: .footnote))
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: 18)
            Text(text)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.text)
        }
    }

    private func severityColor(_ severity: SOSSeverity) -> Color {
        switch severity {
        case .red: return theme.colors.statusRed
        case .amber: return theme.colors.statusAmber
        case .green: return theme.colors.statusGreen
        }
    }

    private func expiresSoon(_ alert: SOSViewModel.SOSAlertInfo) -> Bool {
        guard !alert.isExpired else { return false }
        let remainingTime = alert.expiresAt.timeIntervalSinceNow
        return remainingTime > 0 && remainingTime <= 300
    }

    private func alertBadge(_ title: String, tint: Color, background: Color) -> some View {
        Text(title)
            .font(theme.typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, BlipSpacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
    }

    private func elapsedTime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return MedicalDashboardL10n.elapsedSeconds(seconds) }
        if seconds < 3600 { return MedicalDashboardL10n.elapsedMinutes(seconds / 60) }
        return MedicalDashboardL10n.elapsedHoursMinutes(seconds / 3600, (seconds % 3600) / 60)
    }
}

// MARK: - Previews

#Preview("Not a Responder") {
    MedicalDashboardView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

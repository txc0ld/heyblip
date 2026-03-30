import SwiftUI

// MARK: - MedicalDashboardView

/// Medical responder dashboard placeholder.
///
/// The original version unlocked sample emergency data with a weak client-only
/// code check. This build exposes the feature honestly until organizer auth,
/// responder sync, and live alert routing are wired end to end.
struct MedicalDashboardView: View {

    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: BlipSpacing.xl) {
                        Spacer().frame(height: BlipSpacing.xl)

                        statusHero
                            .staggeredReveal(index: 0)

                        availabilityCard
                            .staggeredReveal(index: 1)

                        readinessChecklist
                            .staggeredReveal(index: 2)

                        Spacer().frame(height: BlipSpacing.xxl)
                    }
                    .padding(.horizontal, BlipSpacing.md)
                }
            }
            .navigationTitle("Medical Dashboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusHero: some View {
        VStack(spacing: BlipSpacing.md) {
            ZStack {
                Circle()
                    .fill(.blipAccentPurple.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "cross.case.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.blipAccentPurple)
            }

            VStack(spacing: BlipSpacing.sm) {
                Text("Responder access is unavailable in this build")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)

                Text("The prior screen unlocked preview incidents locally without organizer verification. It has been replaced with an honest status view until the real responder workflow exists.")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BlipSpacing.lg)
    }

    private var availabilityCard: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                Text("Why it is disabled")
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                statusRow(
                    icon: "lock.shield.fill",
                    title: "Organizer-issued access is not verified server-side yet.",
                    tint: theme.colors.statusAmber
                )

                statusRow(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Live alert dispatch and responder presence are not wired to production data.",
                    tint: theme.colors.statusAmber
                )

                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Emergency surfaces cannot use fabricated sample incidents without weakening trust.",
                    tint: theme.colors.statusRed
                )
            }
        }
    }

    private var readinessChecklist: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                Text("Required before this screen can go live")
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                checklistRow("Server-backed responder authentication")
                checklistRow("Live SOS alert feed for authorized responders")
                checklistRow("Accepted / navigating / resolved state sync")
                checklistRow("Real-device validation with festival staff workflows")
            }
        }
    }

    private func statusRow(icon: String, title: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(title)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.text)
        }
    }

    private func checklistRow(_ title: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.colors.mutedText)

            Text(title)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
    }
}

// MARK: - Preview

#Preview("Medical Dashboard") {
    MedicalDashboardView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

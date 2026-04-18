import SwiftUI
import SwiftData

private enum VerifiedProfileL10n {
    static let title = String(localized: "profile.verified.sheet.title", defaultValue: "Get Verified")
    static let subtitle = String(localized: "profile.verified.sheet.subtitle", defaultValue: "Stand out and build trust in the mesh")
    static let badgeTitle = String(localized: "profile.verified.benefit.badge.title", defaultValue: "Purple Verified Badge")
    static let badgeDescription = String(localized: "profile.verified.benefit.badge.description", defaultValue: "Visible on your profile and in every chat")
    static let priorityTitle = String(localized: "profile.verified.benefit.priority.title", defaultValue: "Priority in Nearby")
    static let priorityDescription = String(localized: "profile.verified.benefit.priority.description", defaultValue: "Appear higher in peer discovery results")
    static let trustTitle = String(localized: "profile.verified.benefit.trust.title", defaultValue: "Trust Indicator")
    static let trustDescription = String(localized: "profile.verified.benefit.trust.description", defaultValue: "Friends see you're a verified community member")
    static let oneTimePurchase = String(localized: "profile.verified.price.title", defaultValue: "One-time purchase")
    static let forever = String(localized: "profile.verified.price.forever", defaultValue: "Forever")
    static let unavailable = String(localized: "profile.verified.unavailable.title", defaultValue: "Verification purchases are unavailable in this build.")
    static let unavailableSubtitle = String(localized: "profile.verified.unavailable.subtitle", defaultValue: "The previous CTA only flipped local state, so it has been disabled until StoreKit and server-backed verification are wired.")
    static let maybeLater = String(localized: "common.maybe_later", defaultValue: "Maybe Later")
    static let verified = String(localized: "profile.verified.status", defaultValue: "Verified")
}

// MARK: - VerifiedProfileSheet

/// Sheet explaining verified profile benefits and handling the purchase.
/// One-time $14.99 purchase via StoreKit 2 for `com.blip.verified`.
struct VerifiedProfileSheet: View {

    @Binding var isPresented: Bool

    @Query private var users: [User]

    @Environment(\.theme) private var theme

    private var user: User? { users.first }

    var body: some View {
        ZStack {
            GradientBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BlipSpacing.lg) {
                    headerSection
                    benefitsSection
                    priceSection
                    ctaSection

                }
                .padding(BlipSpacing.lg)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: BlipSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.blipAccentPurple.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blipAccentPurple)
            }

            Text(VerifiedProfileL10n.title)
                .font(theme.typography.largeTitle)
                .foregroundStyle(theme.colors.text)

            Text(VerifiedProfileL10n.subtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Benefits

    private var benefitsSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                benefitRow(
                    icon: "checkmark.seal.fill",
                    title: VerifiedProfileL10n.badgeTitle,
                    description: VerifiedProfileL10n.badgeDescription
                )

                benefitRow(
                    icon: "star.fill",
                    title: VerifiedProfileL10n.priorityTitle,
                    description: VerifiedProfileL10n.priorityDescription
                )

                benefitRow(
                    icon: "shield.fill",
                    title: VerifiedProfileL10n.trustTitle,
                    description: VerifiedProfileL10n.trustDescription
                )
            }
        }
    }

    private func benefitRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: BlipSpacing.md) {
            Image(systemName: icon)
                .font(theme.typography.body)
                .foregroundStyle(.blipAccentPurple)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                Text(title)
                    .font(theme.typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                Text(description)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - Price

    private var priceSection: some View {
        GlassCard(thickness: .regular) {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(VerifiedProfileL10n.oneTimePurchase)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)

                    Text("$14.99")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.blipAccentPurple)
                }

                Spacer()

                Text(VerifiedProfileL10n.forever)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: BlipSpacing.md) {
            if user?.isVerified == true {
                alreadyVerifiedView
            } else {
                GlassCard(thickness: .regular) {
                    VStack(spacing: BlipSpacing.sm) {
                        // TODO: BDEV-136 — wire StoreKit 2 purchase for com.blip.verified product
                        Text(VerifiedProfileL10n.unavailable)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                            .multilineTextAlignment(.center)

                        Text(VerifiedProfileL10n.unavailableSubtitle)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            Button(action: { isPresented = false }) {
                Text(VerifiedProfileL10n.maybeLater)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minHeight: BlipSizing.minTapTarget)
        }
    }

    private var alreadyVerifiedView: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.blipAccentPurple)
            Text(VerifiedProfileL10n.verified)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

}

// MARK: - Preview

#Preview("Verified Sheet") {
    VerifiedProfileSheet(isPresented: .constant(true))
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("Verified Sheet - Light") {
    VerifiedProfileSheet(isPresented: .constant(true))
        .preferredColorScheme(.light)
        .blipTheme()
}

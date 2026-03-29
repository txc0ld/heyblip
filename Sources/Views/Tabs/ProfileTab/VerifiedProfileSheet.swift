import SwiftUI
import SwiftData

// MARK: - VerifiedProfileSheet

/// Sheet explaining verified profile benefits and handling the purchase.
/// One-time $14.99 purchase via StoreKit 2 for `com.blip.verified`.
struct VerifiedProfileSheet: View {

    @Binding var isPresented: Bool

    @Query private var users: [User]
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var purchaseSuccess = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

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

                    if let error = purchaseError {
                        errorBanner(error)
                    }
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

            Text("Get Verified")
                .font(theme.typography.largeTitle)
                .foregroundStyle(theme.colors.text)

            Text("Stand out and build trust in the mesh")
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
                    title: "Purple Verified Badge",
                    description: "Visible on your profile and in every chat"
                )

                benefitRow(
                    icon: "star.fill",
                    title: "Priority in Nearby",
                    description: "Appear higher in peer discovery results"
                )

                benefitRow(
                    icon: "shield.fill",
                    title: "Trust Indicator",
                    description: "Friends see you're a verified community member"
                )
            }
        }
    }

    private func benefitRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: BlipSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
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
                    Text("One-time purchase")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)

                    Text("$14.99")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.blipAccentPurple)
                }

                Spacer()

                Text("Forever")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: BlipSpacing.md) {
            if purchaseSuccess {
                successView
            } else if user?.isVerified == true {
                alreadyVerifiedView
            } else {
                GlassButton(
                    "Get Verified - $14.99",
                    icon: "checkmark.seal",
                    isLoading: isPurchasing
                ) {
                    purchaseVerified()
                }
                .fullWidth()
            }

            Button(action: { isPresented = false }) {
                Text("Maybe Later")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minHeight: BlipSizing.minTapTarget)
        }
    }

    private var successView: some View {
        VStack(spacing: BlipSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blipAccentPurple)

            Text("You're Verified!")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
        }
    }

    private var alreadyVerifiedView: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.blipAccentPurple)
            Text("Verified")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        GlassCard(thickness: .regular) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BlipColors.adaptive.statusAmber)
                Text(message)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - Purchase

    private func purchaseVerified() {
        isPurchasing = true
        purchaseError = nil

        // StoreKit 2 purchase will be wired via StoreViewModel.
        // For now, set isVerified directly for development.
        Task { @MainActor in
            defer { isPurchasing = false }

            if let user {
                user.isVerified = true
                try? modelContext.save()
                purchaseSuccess = true
            }
        }
    }
}

// MARK: - Preview

#Preview("Verified Sheet") {
    VerifiedProfileSheet(isPresented: .constant(true))
        .preferredColorScheme(.dark)
        .festiChatTheme()
}

#Preview("Verified Sheet - Light") {
    VerifiedProfileSheet(isPresented: .constant(true))
        .preferredColorScheme(.light)
        .festiChatTheme()
}

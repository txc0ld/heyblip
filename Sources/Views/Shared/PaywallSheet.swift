import SwiftUI

// MARK: - PaywallSheet

/// Soft glass sheet with message pack options and one-tap StoreKit purchase.
/// "Your message will send immediately after purchase."
struct PaywallSheet: View {

    @State private var selectedPack: PackOption? = nil
    @State private var isPurchasing = false
    @State private var purchaseSuccess = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            GradientBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: BlipSpacing.lg) {
                    // Handle indicator
                    Capsule()
                        .fill(theme.colors.mutedText.opacity(0.3))
                        .frame(width: 36, height: 4)
                        .padding(.top, BlipSpacing.md)

                    // Header
                    headerSection

                    // Pack options
                    packOptionsSection

                    // Purchase button
                    purchaseButton

                    // Fine print
                    finePrint
                }
                .padding(.horizontal, BlipSpacing.lg)
                .padding(.bottom, BlipSpacing.xl)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(BlipCornerRadius.xxl)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.blipAccentPurple,
                            Color(red: 0.55, green: 0.15, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Get more messages")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("Your message will send immediately after purchase.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Pack Options

    private var packOptionsSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            ForEach(PackOption.allOptions) { pack in
                packCard(pack)
            }
        }
    }

    private func packCard(_ pack: PackOption) -> some View {
        let isSelected = selectedPack?.id == pack.id

        return Button {
            withAnimation(SpringConstants.bouncyAnimation) {
                selectedPack = pack
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    HStack(spacing: BlipSpacing.sm) {
                        Text(pack.name)
                            .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                            .foregroundStyle(theme.colors.text)

                        if pack.isBestValue {
                            Text("BEST VALUE")
                                .font(.custom(BlipFontName.bold, size: 9, relativeTo: .caption2))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.blipAccentPurple)
                                )
                        }
                    }

                    Text("\(pack.messageCount) messages")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Text(pack.priceFormatted)
                    .font(.custom(BlipFontName.bold, size: 18, relativeTo: .title3))
                    .foregroundStyle(theme.colors.text)
            }
            .padding(BlipSpacing.md)
            .background(cardBackground(isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.blipAccentPurple
                            : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                        lineWidth: isSelected ? 1.5 : BlipSizing.hairline
                    )
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(pack.name), \(pack.messageCount) messages, \(pack.priceFormatted)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func cardBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .fill(Color.blipAccentPurple.opacity(0.08))
                )
        } else {
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        GlassButton(
            purchaseSuccess
                ? "Purchased!"
                : (selectedPack != nil ? "Buy \(selectedPack!.name) - \(selectedPack!.priceFormatted)" : "Select a pack"),
            icon: purchaseSuccess ? "checkmark" : "cart.fill",
            isLoading: isPurchasing
        ) {
            guard selectedPack != nil else { return }
            purchase()
        }
        .fullWidth()
        .disabled(selectedPack == nil || isPurchasing)
    }

    // MARK: - Fine Print

    private var finePrint: some View {
        VStack(spacing: BlipSpacing.xs) {
            Text("Receiving messages is always free.")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)

            HStack(spacing: BlipSpacing.md) {
                Button("Restore Purchases") {
                    // Restore logic
                }
                .font(theme.typography.caption)
                .foregroundStyle(Color.blipAccentPurple)
                .frame(minHeight: BlipSizing.minTapTarget)

                Button("Terms") {
                    // Terms
                }
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .frame(minHeight: BlipSizing.minTapTarget)

                Button("Privacy") {
                    // Privacy
                }
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .frame(minHeight: BlipSizing.minTapTarget)
            }
        }
    }

    // MARK: - Purchase

    private func purchase() {
        isPurchasing = true
        // Simulated purchase for development
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isPurchasing = false
            withAnimation(SpringConstants.bouncyAnimation) {
                purchaseSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
            }
        }
    }
}

// MARK: - PackOption

struct PackOption: Identifiable, Sendable {
    let id: String
    let name: String
    let messageCount: Int
    let priceFormatted: String
    let isBestValue: Bool

    static let allOptions: [PackOption] = [
        PackOption(id: "starter10", name: "Starter", messageCount: 10, priceFormatted: "$0.99", isBestValue: false),
        PackOption(id: "social25", name: "Social", messageCount: 25, priceFormatted: "$1.99", isBestValue: false),
        PackOption(id: "festival50", name: "Festival", messageCount: 50, priceFormatted: "$3.99", isBestValue: true),
        PackOption(id: "squad100", name: "Squad", messageCount: 100, priceFormatted: "$5.99", isBestValue: false),
        PackOption(id: "season1000", name: "Season Pass", messageCount: 1000, priceFormatted: "$29.99", isBestValue: false)
    ]
}

// MARK: - Preview

#Preview("Paywall Sheet") {
    PaywallSheet()
        .environment(\.theme, Theme.shared)
}

#Preview("Paywall Sheet - Light") {
    PaywallSheet()
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}

#Preview("Paywall Sheet - In Context") {
    struct PaywallPreview: View {
        @State private var showPaywall = true
        var body: some View {
            ZStack {
                GradientBackground()
                Text("Chat View")
                    .foregroundStyle(.white)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallSheet()
            }
            .environment(\.theme, Theme.shared)
        }
    }
    return PaywallPreview()
}

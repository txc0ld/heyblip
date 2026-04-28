import SwiftUI
import SwiftData

private enum PaywallSheetL10n {
    static let purchaseComplete = String(localized: "store.paywall.purchase_complete.title", defaultValue: "Purchase Complete")
    static let continueButton = String(localized: "common.continue", defaultValue: "Continue")
    static let purchaseCompleteMessage = String(localized: "store.paywall.purchase_complete.message", defaultValue: "Your message balance has been updated.")
    static let purchaseError = String(localized: "store.paywall.purchase_error.title", defaultValue: "Purchase Error")
    static let ok = String(localized: "common.ok", defaultValue: "OK")
    static let title = String(localized: "store.paywall.title", defaultValue: "Get more messages")
    static let subtitle = String(localized: "store.paywall.subtitle", defaultValue: "Buy message credits to keep chatting. Credits update after App Store confirmation.")
    static let loading = String(localized: "store.paywall.loading", defaultValue: "Loading message packs")
    static let unavailableTitle = String(localized: "store.paywall.unavailable.title", defaultValue: "Message packs are unavailable")
    static let unavailableSubtitle = String(localized: "store.paywall.unavailable.subtitle", defaultValue: "The App Store catalog did not load on this device.")
    static let tryAgain = String(localized: "common.try_again", defaultValue: "Try Again")
    static let bestValue = String(localized: "store.paywall.badge.best_value", defaultValue: "BEST VALUE")
    static let purchased = String(localized: "store.paywall.purchase_button.purchased", defaultValue: "Purchased!")
    static let selectPack = String(localized: "store.paywall.purchase_button.select_pack", defaultValue: "Select a pack")
    static let receivingFree = String(localized: "store.paywall.fine_print.receiving_free", defaultValue: "Receiving messages is always free.")
    static let restorePurchases = String(localized: "store.paywall.restore", defaultValue: "Restore Purchases")
    static let balanceUpdated = String(localized: "store.paywall.fine_print.balance_updated", defaultValue: "After your balance updates, head back to chat and send again.")

    static func messagesCount(_ count: Int) -> String {
        String(
            format: String(localized: "store.paywall.pack.messages_count", defaultValue: "%d messages"),
            locale: Locale.current,
            count
        )
    }

    static func accessibilityLabel(name: String, count: Int, price: String) -> String {
        String(
            format: String(localized: "store.paywall.pack.accessibility_label", defaultValue: "%@, %d messages, %@"),
            locale: Locale.current,
            name,
            count,
            price
        )
    }

    static func buyButton(productName: String, productPrice: String) -> String {
        String(
            format: String(localized: "store.paywall.purchase_button.buy_format", defaultValue: "Buy %@ - %@"),
            locale: Locale.current,
            productName,
            productPrice
        )
    }
}

// MARK: - PaywallSheet

/// Soft glass sheet with message pack options and one-tap StoreKit purchase.
/// "Your message will send immediately after purchase."
struct PaywallSheet: View {

    var storeViewModel: StoreViewModel? = nil

    @State private var localStoreViewModel: StoreViewModel?
    @State private var selectedProductID: String?
    @State private var purchaseSuccess = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    private var resolvedStoreViewModel: StoreViewModel? { storeViewModel ?? localStoreViewModel }

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
        .task {
            if resolvedStoreViewModel == nil {
                localStoreViewModel = StoreViewModel(modelContainer: modelContext.container)
            }
            guard let vm = resolvedStoreViewModel else { return }
            await vm.start()
            if selectedProduct == nil {
                selectedProductID = availableProducts.first?.id
            }
        }
        .alert(PaywallSheetL10n.purchaseComplete, isPresented: $purchaseSuccess) {
            Button(PaywallSheetL10n.continueButton) {
                resolvedStoreViewModel?.clearMessages()
                dismiss()
            }
        } message: {
            Text(resolvedStoreViewModel?.successMessage ?? PaywallSheetL10n.purchaseCompleteMessage)
        }
        .alert(PaywallSheetL10n.purchaseError, isPresented: Binding(
            get: { resolvedStoreViewModel?.errorMessage != nil },
            set: { if !$0 { resolvedStoreViewModel?.clearMessages() } }
        )) {
            Button(PaywallSheetL10n.ok) { resolvedStoreViewModel?.clearMessages() }
        } message: {
            Text(resolvedStoreViewModel?.errorMessage ?? "")
        }
        .onChange(of: resolvedStoreViewModel?.successMessage) { _, newValue in
            if newValue != nil {
                purchaseSuccess = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .blipTextStyle(.display)
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

            Text(PaywallSheetL10n.title)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(PaywallSheetL10n.subtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Pack Options

    private var packOptionsSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            if resolvedStoreViewModel?.isLoadingProducts == true {
                // Skeleton stack mirrors the eventual `packCard` rows so the
                // loaded paywall reads as a fade-in rather than a re-layout.
                VStack(spacing: BlipSpacing.sm) {
                    ForEach(0..<3, id: \.self) { _ in
                        Skeleton(.productPack)
                    }
                }
                .accessibilityLabel(PaywallSheetL10n.loading)
            } else if !availableProducts.isEmpty {
                ForEach(availableProducts) { product in
                    packCard(product)
                }
            } else {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "cart.badge.questionmark")
                            .font(theme.typography.title1)
                            .foregroundStyle(theme.colors.mutedText)

                        Text(PaywallSheetL10n.unavailableTitle)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)

                        Text(resolvedStoreViewModel?.errorMessage ?? PaywallSheetL10n.unavailableSubtitle)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        GlassButton(PaywallSheetL10n.tryAgain, icon: "arrow.clockwise", style: .secondary, size: .small) {
                            Task { await resolvedStoreViewModel?.loadProducts() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.lg)
                }
            }
        }
    }

    private func packCard(_ product: ProductInfo) -> some View {
        let isSelected = selectedProductID == product.id

        return Button {
            withAnimation(SpringConstants.bouncyAnimation) {
                selectedProductID = product.id
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    HStack(spacing: BlipSpacing.sm) {
                        Text(product.displayName)
                            .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                            .foregroundStyle(theme.colors.text)

                        if product.messageCount == 50 {
                            Text(PaywallSheetL10n.bestValue)
                                .font(.custom(BlipFontName.bold, size: 9, relativeTo: .caption2))
                                .foregroundStyle(.white)
                                .padding(.horizontal, BlipSpacing.sm)
                                .padding(.vertical, BlipSpacing.xxs)
                                .background(
                                    Capsule()
                                        .fill(Color.blipAccentPurple)
                                )
                        }
                    }

                    Text(PaywallSheetL10n.messagesCount(product.messageCount))
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Text(product.displayPrice)
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
        .accessibilityLabel(PaywallSheetL10n.accessibilityLabel(name: product.displayName, count: product.messageCount, price: product.displayPrice))
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
        let buttonTitle: String = {
            if purchaseSuccess {
                return PaywallSheetL10n.purchased
            }
            guard let product = selectedProduct else {
                return PaywallSheetL10n.selectPack
            }
            return PaywallSheetL10n.buyButton(productName: product.displayName, productPrice: product.displayPrice)
        }()

        return GlassButton(
            buttonTitle,
            icon: purchaseSuccess ? "checkmark" : "cart.fill",
            isLoading: resolvedStoreViewModel?.isPurchasing == true
        ) {
            guard let selectedProduct else { return }
            Task {
                await resolvedStoreViewModel?.purchase(selectedProduct)
            }
        }
        .fullWidth()
        .disabled(selectedProduct == nil || resolvedStoreViewModel?.isPurchasing == true)
    }

    // MARK: - Fine Print

    private var finePrint: some View {
        VStack(spacing: BlipSpacing.xs) {
            Text(PaywallSheetL10n.receivingFree)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)

            HStack(spacing: BlipSpacing.md) {
                Button(PaywallSheetL10n.restorePurchases) {
                    Task { await resolvedStoreViewModel?.restorePurchases() }
                }
                .font(theme.typography.caption)
                .foregroundStyle(Color.blipAccentPurple)
                .frame(minHeight: BlipSizing.minTapTarget)
                .disabled(resolvedStoreViewModel?.isRestoring == true)

                Text(PaywallSheetL10n.balanceUpdated)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
            }
        }
    }

    private var availableProducts: [ProductInfo] {
        (resolvedStoreViewModel?.products ?? []).filter { !$0.isSubscription }
    }

    private var selectedProduct: ProductInfo? {
        guard let selectedProductID else { return availableProducts.first }
        return availableProducts.first { $0.id == selectedProductID } ?? availableProducts.first
    }
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

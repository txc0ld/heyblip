import SwiftUI
import SwiftData

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
        .alert("Purchase Complete", isPresented: $purchaseSuccess) {
            Button("Continue") {
                resolvedStoreViewModel?.clearMessages()
                dismiss()
            }
        } message: {
            Text(resolvedStoreViewModel?.successMessage ?? "Your message balance has been updated.")
        }
        .alert("Purchase Error", isPresented: Binding(
            get: { resolvedStoreViewModel?.errorMessage != nil },
            set: { if !$0 { resolvedStoreViewModel?.clearMessages() } }
        )) {
            Button("OK") { resolvedStoreViewModel?.clearMessages() }
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

            Text("Buy message credits to keep chatting. Credits update after App Store confirmation.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Pack Options

    private var packOptionsSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            if resolvedStoreViewModel?.isLoadingProducts == true {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        ProgressView()
                        Text("Loading message packs")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.lg)
                }
            } else if !availableProducts.isEmpty {
                ForEach(availableProducts) { product in
                    packCard(product)
                }
            } else {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "cart.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.colors.mutedText)

                        Text("Message packs are unavailable")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)

                        Text(resolvedStoreViewModel?.errorMessage ?? "The App Store catalog did not load on this device.")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        GlassButton("Try Again", icon: "arrow.clockwise", style: .secondary, size: .small) {
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

                        if product.packType == .festival50 {
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

                    Text("\(product.messageCount) messages")
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
        .accessibilityLabel("\(product.displayName), \(product.messageCount) messages, \(product.displayPrice)")
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
                : (selectedProduct != nil ? "Buy \(selectedProduct!.displayName) - \(selectedProduct!.displayPrice)" : "Select a pack"),
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
            Text("Receiving messages is always free.")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)

            HStack(spacing: BlipSpacing.md) {
                Button("Restore Purchases") {
                    Task { await resolvedStoreViewModel?.restorePurchases() }
                }
                .font(theme.typography.caption)
                .foregroundStyle(Color.blipAccentPurple)
                .frame(minHeight: BlipSizing.minTapTarget)
                .disabled(resolvedStoreViewModel?.isRestoring == true)

                Text("After your balance updates, head back to chat and send again.")
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

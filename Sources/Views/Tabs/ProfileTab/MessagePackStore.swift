import SwiftUI
import SwiftData
import StoreKit

// MARK: - MessagePackStore

/// StoreKit 2 product cards for message packs, purchase flow, and balance.
/// Wired to real StoreViewModel for product loading and purchases.
struct MessagePackStore: View {

    var storeViewModel: StoreViewModel? = nil

    @State private var localStoreViewModel: StoreViewModel?
    @State private var showPurchaseSuccess = false
    @State private var showVerifiedSheet = false

    @Query private var users: [User]
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    private var user: User? { users.first }
    private var resolvedStoreViewModel: StoreViewModel? { storeViewModel ?? localStoreViewModel }

    var body: some View {
        ZStack {
            GradientBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BlipSpacing.lg) {
                    // Featured: Verified profile
                    verifiedFeatureCard
                        .staggeredReveal(index: 0)

                    balanceHeader
                        .staggeredReveal(index: 1)

                    packGrid
                        .staggeredReveal(index: 2)

                    subscriptionCard
                        .staggeredReveal(index: 3)

                    freeMessageInfo
                        .staggeredReveal(index: 4)

                    // Restore purchases
                    restoreButton
                        .staggeredReveal(index: 5)

                    Spacer().frame(height: BlipSpacing.xxl)
                }
                .padding(BlipSpacing.md)
            }
        }
        .navigationTitle("Message Packs")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if resolvedStoreViewModel == nil {
                localStoreViewModel = StoreViewModel(modelContainer: modelContext.container)
            }
            guard let vm = resolvedStoreViewModel else { return }
            await vm.start()
        }
        .alert("Purchase Complete", isPresented: $showPurchaseSuccess) {
            Button("OK") { resolvedStoreViewModel?.clearMessages() }
        } message: {
            Text(resolvedStoreViewModel?.successMessage ?? "Purchase successful!")
        }
        .alert("Error", isPresented: Binding(
            get: { resolvedStoreViewModel?.errorMessage != nil },
            set: { if !$0 { resolvedStoreViewModel?.clearMessages() } }
        )) {
            Button("OK") { resolvedStoreViewModel?.clearMessages() }
        } message: {
            Text(resolvedStoreViewModel?.errorMessage ?? "")
        }
        .onChange(of: resolvedStoreViewModel?.successMessage) { _, newValue in
            if newValue != nil {
                showPurchaseSuccess = true
            }
        }
        .sheet(isPresented: $showVerifiedSheet) {
            VerifiedProfileSheet(isPresented: $showVerifiedSheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Verified Feature Card

    private var verifiedFeatureCard: some View {
        Button(action: { showVerifiedSheet = true }) {
            GlassCard(thickness: .regular) {
                HStack(spacing: BlipSpacing.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blipAccentPurple)

                    VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                        if user?.isVerified == true {
                            HStack(spacing: BlipSpacing.xs) {
                                Text("Verified")
                                    .font(theme.typography.body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(theme.colors.mutedText)
                                Image(systemName: "checkmark")
                                    .font(theme.typography.caption)
                                    .foregroundStyle(.blipAccentPurple)
                            }
                        } else {
                            Text("Get Verified")
                                .font(theme.typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable until StoreKit verification is wired")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                    }

                    Spacer()

                    Image(systemName: "info.circle")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(user?.isVerified == true)
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(Color.blipAccentPurple.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Balance Header

    private var balanceHeader: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.sm) {
                Text("Current Balance")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                let balance = resolvedStoreViewModel?.messageBalance ?? 0

                HStack(alignment: .firstTextBaseline, spacing: BlipSpacing.xs) {
                    Text(resolvedStoreViewModel?.balanceDisplay ?? "\(balance)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.blipAccentPurple)
                        .contentTransition(.numericText())

                    Text("messages")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                }

                if balance <= 5 && resolvedStoreViewModel?.isUnlimited != true {
                    HStack(spacing: BlipSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BlipColors.adaptive.statusAmber)

                        Text("Running low!")
                            .font(theme.typography.caption)
                            .foregroundStyle(BlipColors.adaptive.statusAmber)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pack Grid

    private var packGrid: some View {
        VStack(spacing: BlipSpacing.md) {
            Text("Buy Messages")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if resolvedStoreViewModel?.isLoadingProducts == true {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let products = resolvedStoreViewModel?.products, !products.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: BlipSpacing.md),
                    GridItem(.flexible(), spacing: BlipSpacing.md),
                ], spacing: BlipSpacing.md) {
                    ForEach(products.filter { !$0.isSubscription }) { product in
                        packCard(product)
                    }
                }
            } else {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.md) {
                        Image(systemName: "cart.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.colors.mutedText)

                        Text("Message packs are unavailable right now")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                            .multilineTextAlignment(.center)

                        Text(resolvedStoreViewModel?.errorMessage ?? "The App Store catalog did not load on this device. Retry when network and StoreKit are available.")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        GlassButton("Retry Store", icon: "arrow.clockwise", style: .secondary, size: .small) {
                            Task { await resolvedStoreViewModel?.loadProducts() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
    }

    private func packCard(_ product: ProductInfo) -> some View {
        let isBestValue = product.packType == .festival50

        return Button(action: {
            Task { await resolvedStoreViewModel?.purchase(product) }
        }) {
            VStack(spacing: BlipSpacing.md) {
                Image(systemName: "message.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blipAccentPurple)

                Text(product.displayName)
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                Text("\(product.messageCount) messages")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                Text(product.displayPrice)
                    .font(theme.typography.body)
                    .fontWeight(.bold)
                    .foregroundStyle(.blipAccentPurple)
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.vertical, BlipSpacing.sm)
                    .background(
                        Capsule()
                            .fill(.blipAccentPurple.opacity(0.12))
                    )

                if isBestValue {
                    Text("BEST VALUE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LinearGradient.blipAccent))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.md)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(
            thickness: isBestValue ? .regular : .ultraThin,
            cornerRadius: BlipCornerRadius.xl,
            borderOpacity: isBestValue ? 0.3 : 0.1
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(isBestValue ? .blipAccentPurple.opacity(0.3) : .clear, lineWidth: 1)
        )
        .disabled(resolvedStoreViewModel?.isPurchasing == true)
        .accessibilityLabel("\(product.displayName): \(product.messageCount) messages for \(product.displayPrice)")
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.blipAccentPurple)

                    Text("Unlimited")
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Spacer()

                    Text("Coming Soon")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(theme.colors.hover))
                }

                Text("Unlimited messages with a monthly or seasonal subscription. Plus a subscriber badge on your avatar.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.leading)

                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.mutedText)

                    Text("Subscription signup is not enabled in this build, so the CTA has been removed until the entitlement flow is live.")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Restore Button

    private var restoreButton: some View {
        Button(action: {
            Task { await resolvedStoreViewModel?.restorePurchases() }
        }) {
            HStack(spacing: BlipSpacing.sm) {
                if resolvedStoreViewModel?.isRestoring == true {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Text("Restore Purchases")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minHeight: BlipSizing.minTapTarget)
        }
        .disabled(resolvedStoreViewModel?.isRestoring == true)
    }

    // MARK: - Free Message Info

    private var freeMessageInfo: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text("What counts as a message?")
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    infoRow(icon: "text.bubble", text: "1 text = 1 message")
                    infoRow(icon: "mic.fill", text: "1 voice note = 1 message")
                    infoRow(icon: "photo", text: "1 image = 1 message")
                    infoRow(icon: "waveform", text: "1 PTT session = 1 message")
                }

                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    infoRow(icon: "checkmark.circle", text: "Receiving messages = always free")
                    infoRow(icon: "checkmark.circle", text: "Location broadcasts = free")
                    infoRow(icon: "checkmark.circle", text: "Friend requests = free")
                    infoRow(icon: "checkmark.circle", text: "Delivery receipts = free")
                }
            }
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: 20)

            Text(text)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
    }
}

// MARK: - Preview

#Preview("Message Pack Store") {
    NavigationStack {
        MessagePackStore()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Message Pack Store - Light") {
    NavigationStack {
        MessagePackStore()
    }
    .preferredColorScheme(.light)
    .blipTheme()
}

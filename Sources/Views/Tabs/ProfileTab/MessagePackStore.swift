import SwiftUI
import SwiftData
import StoreKit

private enum MessagePackStoreL10n {
    static let title = String(localized: "store.message_pack.title", defaultValue: "Message Packs")
    static let purchaseComplete = String(localized: "store.message_pack.purchase_complete.title", defaultValue: "Purchase Complete")
    static let ok = String(localized: "common.ok", defaultValue: "OK")
    static let purchaseSuccess = String(localized: "store.message_pack.purchase_complete.message", defaultValue: "Purchase successful!")
    static let error = String(localized: "common.error", defaultValue: "Error")
    static let verified = String(localized: "profile.verified.status", defaultValue: "Verified")
    static let getVerified = String(localized: "profile.verified.cta", defaultValue: "Get Verified")
    static let verifiedUnavailable = String(localized: "profile.verified.unavailable", defaultValue: "Unavailable until StoreKit verification is wired")
    static let currentBalance = String(localized: "store.message_pack.balance.title", defaultValue: "Current Balance")
    static let unlimited = String(localized: "store.message_pack.balance.unlimited", defaultValue: "Unlimited")
    static let messages = String(localized: "store.message_pack.balance.unit", defaultValue: "messages")
    static let buyMessages = String(localized: "store.message_pack.buy_messages", defaultValue: "Buy Messages")
    static let unavailableNow = String(localized: "store.message_pack.unavailable.title", defaultValue: "Message packs are unavailable right now")
    static let unavailableSubtitle = String(localized: "store.message_pack.unavailable.subtitle", defaultValue: "The App Store catalog did not load on this device. Retry when network and StoreKit are available.")
    static let retryStore = String(localized: "store.message_pack.retry", defaultValue: "Retry Store")
    static let bestValue = String(localized: "store.message_pack.badge.best_value", defaultValue: "BEST VALUE")
    static let subscriptionTitle = String(localized: "store.message_pack.subscription.title", defaultValue: "Unlimited")
    static let comingSoon = String(localized: "common.coming_soon", defaultValue: "Coming Soon")
    static let subscriptionSubtitle = String(localized: "store.message_pack.subscription.subtitle", defaultValue: "Unlimited messages with a monthly or seasonal subscription. Plus a subscriber badge on your avatar.")
    static let subscriptionNotice = String(localized: "store.message_pack.subscription.notice", defaultValue: "Subscription signup is not enabled in this build, so the CTA has been removed until the entitlement flow is live.")
    static let restorePurchases = String(localized: "store.message_pack.restore", defaultValue: "Restore Purchases")
    static let whatCounts = String(localized: "store.message_pack.what_counts", defaultValue: "What counts as a message?")
    static let oneText = String(localized: "store.message_pack.info.one_text", defaultValue: "1 text = 1 message")
    static let oneVoice = String(localized: "store.message_pack.info.one_voice", defaultValue: "1 voice note = 1 message")
    static let oneImage = String(localized: "store.message_pack.info.one_image", defaultValue: "1 image = 1 message")
    static let onePTT = String(localized: "store.message_pack.info.one_ptt", defaultValue: "1 PTT session = 1 message")
    static let receivingFree = String(localized: "store.message_pack.info.receiving_free", defaultValue: "Receiving messages = always free")
    static let locationFree = String(localized: "store.message_pack.info.location_free", defaultValue: "Location broadcasts = free")
    static let friendRequestsFree = String(localized: "store.message_pack.info.friend_requests_free", defaultValue: "Friend requests = free")
    static let receiptsFree = String(localized: "store.message_pack.info.receipts_free", defaultValue: "Delivery receipts = free")

    static func messageCount(_ count: Int) -> String {
        String(format: String(localized: "store.message_pack.product.message_count", defaultValue: "%d messages"), locale: Locale.current, count)
    }

    static func accessibilityLabel(name: String, count: Int, price: String) -> String {
        String(format: String(localized: "store.message_pack.product.accessibility_label", defaultValue: "%@: %d messages for %@"), locale: Locale.current, name, count, price)
    }
}

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
        .navigationTitle(MessagePackStoreL10n.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if resolvedStoreViewModel == nil {
                localStoreViewModel = StoreViewModel(modelContainer: modelContext.container)
            }
            guard let vm = resolvedStoreViewModel else { return }
            await vm.start()
        }
        .alert(MessagePackStoreL10n.purchaseComplete, isPresented: $showPurchaseSuccess) {
            Button(MessagePackStoreL10n.ok) { resolvedStoreViewModel?.clearMessages() }
        } message: {
            Text(resolvedStoreViewModel?.successMessage ?? MessagePackStoreL10n.purchaseSuccess)
        }
        .alert(MessagePackStoreL10n.error, isPresented: Binding(
            get: { resolvedStoreViewModel?.errorMessage != nil },
            set: { if !$0 { resolvedStoreViewModel?.clearMessages() } }
        )) {
            Button(MessagePackStoreL10n.ok) { resolvedStoreViewModel?.clearMessages() }
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
                                Text(MessagePackStoreL10n.verified)
                                    .font(theme.typography.body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(theme.colors.mutedText)
                                Image(systemName: "checkmark")
                                    .font(theme.typography.caption)
                                    .foregroundStyle(.blipAccentPurple)
                            }
                        } else {
                            Text(MessagePackStoreL10n.getVerified)
                                .font(theme.typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.colors.text)

                            Text(MessagePackStoreL10n.verifiedUnavailable)
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
                Text(MessagePackStoreL10n.currentBalance)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                HStack(alignment: .firstTextBaseline, spacing: BlipSpacing.xs) {
                    Text(MessagePackStoreL10n.unlimited)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.blipAccentPurple)
                        .contentTransition(.numericText())

                    Text(MessagePackStoreL10n.messages)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                }

            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pack Grid

    private var packGrid: some View {
        VStack(spacing: BlipSpacing.md) {
            Text(MessagePackStoreL10n.buyMessages)
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

                        Text(MessagePackStoreL10n.unavailableNow)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                            .multilineTextAlignment(.center)

                        Text(resolvedStoreViewModel?.errorMessage ?? MessagePackStoreL10n.unavailableSubtitle)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        GlassButton(MessagePackStoreL10n.retryStore, icon: "arrow.clockwise", style: .secondary, size: .small) {
                            Task { await resolvedStoreViewModel?.loadProducts() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
    }

    private func packCard(_ product: ProductInfo) -> some View {
        let isBestValue = product.messageCount == 50

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

                Text(MessagePackStoreL10n.messageCount(product.messageCount))
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
                    Text(MessagePackStoreL10n.bestValue)
                        .font(theme.typography.captionSmall)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xxs)
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
        .accessibilityLabel(MessagePackStoreL10n.accessibilityLabel(name: product.displayName, count: product.messageCount, price: product.displayPrice))
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.blipAccentPurple)

                    Text(MessagePackStoreL10n.subscriptionTitle)
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Spacer()

                    Text(MessagePackStoreL10n.comingSoon)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(theme.colors.hover))
                }

                Text(MessagePackStoreL10n.subscriptionSubtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.leading)

                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.mutedText)

                    Text(MessagePackStoreL10n.subscriptionNotice)
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
                Text(MessagePackStoreL10n.restorePurchases)
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
                Text(MessagePackStoreL10n.whatCounts)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    infoRow(icon: "text.bubble", text: MessagePackStoreL10n.oneText)
                    infoRow(icon: "mic.fill", text: MessagePackStoreL10n.oneVoice)
                    infoRow(icon: "photo", text: MessagePackStoreL10n.oneImage)
                    infoRow(icon: "waveform", text: MessagePackStoreL10n.onePTT)
                }

                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    infoRow(icon: "checkmark.circle", text: MessagePackStoreL10n.receivingFree)
                    infoRow(icon: "checkmark.circle", text: MessagePackStoreL10n.locationFree)
                    infoRow(icon: "checkmark.circle", text: MessagePackStoreL10n.friendRequestsFree)
                    infoRow(icon: "checkmark.circle", text: MessagePackStoreL10n.receiptsFree)
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

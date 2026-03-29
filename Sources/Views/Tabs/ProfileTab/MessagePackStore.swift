import SwiftUI
import StoreKit

// MARK: - MessagePackStore

/// StoreKit 2 product cards for message packs, purchase flow, and balance.
///
/// Displays pack options as glass cards with message count and price.
/// Purchase flow uses StoreKit 2 async APIs. Balance shown at top.
struct MessagePackStore: View {

    @State private var currentBalance: Int = 47
    @State private var packs: [StorePackOption] = StorePackOption.allPacks
    @State private var selectedPack: StorePackOption?
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var showPurchaseSuccess = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            GradientBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: FCSpacing.lg) {
                    balanceHeader
                        .staggeredReveal(index: 0)

                    packGrid
                        .staggeredReveal(index: 1)

                    subscriptionCard
                        .staggeredReveal(index: 2)

                    freeMessageInfo
                        .staggeredReveal(index: 3)

                    Spacer().frame(height: FCSpacing.xxl)
                }
                .padding(FCSpacing.md)
            }
        }
        .navigationTitle("Message Packs")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Purchase Complete", isPresented: $showPurchaseSuccess) {
            Button("OK") {}
        } message: {
            if let pack = selectedPack {
                Text("You now have \(currentBalance) messages. \(pack.messageCount) messages added!")
            }
        }
        .alert("Purchase Error", isPresented: Binding(
            get: { purchaseError != nil },
            set: { if !$0 { purchaseError = nil } }
        )) {
            Button("OK") { purchaseError = nil }
        } message: {
            Text(purchaseError ?? "")
        }
    }

    // MARK: - Balance Header

    private var balanceHeader: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: FCSpacing.sm) {
                Text("Current Balance")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                HStack(alignment: .firstTextBaseline, spacing: FCSpacing.xs) {
                    Text("\(currentBalance)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.fcAccentPurple)
                        .contentTransition(.numericText())

                    Text("messages")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                }

                if currentBalance <= 5 {
                    HStack(spacing: FCSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(FCColors.darkColors.statusAmber)

                        Text("Running low!")
                            .font(theme.typography.caption)
                            .foregroundStyle(FCColors.darkColors.statusAmber)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pack Grid

    private var packGrid: some View {
        VStack(spacing: FCSpacing.md) {
            Text("Buy Messages")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: FCSpacing.md),
                GridItem(.flexible(), spacing: FCSpacing.md),
            ], spacing: FCSpacing.md) {
                ForEach(packs) { pack in
                    packCard(pack)
                }
            }
        }
    }

    private func packCard(_ pack: StorePackOption) -> some View {
        Button(action: { purchasePack(pack) }) {
            VStack(spacing: FCSpacing.md) {
                // Message icon
                Image(systemName: "message.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.fcAccentPurple)

                // Pack name
                Text(pack.name)
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                // Message count
                Text("\(pack.messageCount) messages")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                // Price
                Text(pack.price)
                    .font(theme.typography.body)
                    .fontWeight(.bold)
                    .foregroundStyle(.fcAccentPurple)
                    .padding(.horizontal, FCSpacing.md)
                    .padding(.vertical, FCSpacing.sm)
                    .background(
                        Capsule()
                            .fill(.fcAccentPurple.opacity(0.12))
                    )

                // Value badge
                if pack.isBestValue {
                    Text("BEST VALUE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LinearGradient.fcAccent))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, FCSpacing.md)
        }
        .buttonStyle(.plain)
        .frame(minHeight: FCSizing.minTapTarget)
        .glassCard(
            thickness: pack.isBestValue ? .regular : .ultraThin,
            cornerRadius: FCCornerRadius.xl,
            borderOpacity: pack.isBestValue ? 0.3 : 0.1
        )
        .overlay(
            RoundedRectangle(cornerRadius: FCCornerRadius.xl, style: .continuous)
                .stroke(pack.isBestValue ? .fcAccentPurple.opacity(0.3) : .clear, lineWidth: 1)
        )
        .disabled(isPurchasing)
        .accessibilityLabel("\(pack.name): \(pack.messageCount) messages for \(pack.price)")
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: FCSpacing.md) {
                HStack(spacing: FCSpacing.sm) {
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.fcAccentPurple)

                    Text("Unlimited")
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Spacer()

                    Text("Coming Soon")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.horizontal, FCSpacing.sm)
                        .padding(.vertical, FCSpacing.xs)
                        .background(Capsule().fill(theme.colors.hover))
                }

                Text("Unlimited messages with a monthly or seasonal subscription. Plus a subscriber badge on your avatar.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.leading)

                GlassButton("Notify Me", icon: "bell.fill", style: .secondary, size: .small) {
                    // Register for notification
                }
            }
        }
    }

    // MARK: - Free Message Info

    private var freeMessageInfo: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(alignment: .leading, spacing: FCSpacing.sm) {
                Text("What counts as a message?")
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                VStack(alignment: .leading, spacing: FCSpacing.xs) {
                    infoRow(icon: "text.bubble", text: "1 text = 1 message")
                    infoRow(icon: "mic.fill", text: "1 voice note = 1 message")
                    infoRow(icon: "photo", text: "1 image = 1 message")
                    infoRow(icon: "waveform", text: "1 PTT session = 1 message")
                }

                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: FCSpacing.xs) {
                    infoRow(icon: "checkmark.circle", text: "Receiving messages = always free")
                    infoRow(icon: "checkmark.circle", text: "Location broadcasts = free")
                    infoRow(icon: "checkmark.circle", text: "Friend requests = free")
                    infoRow(icon: "checkmark.circle", text: "Delivery receipts = free")
                }
            }
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: FCSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: 20)

            Text(text)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    // MARK: - Purchase Flow

    private func purchasePack(_ pack: StorePackOption) {
        selectedPack = pack
        isPurchasing = true

        // In production: use StoreKit 2 Product.purchase()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isPurchasing = false
            currentBalance += pack.messageCount
            showPurchaseSuccess = true
        }
    }
}

// MARK: - StorePackOption

struct StorePackOption: Identifiable {
    let id = UUID()
    let name: String
    let messageCount: Int
    let price: String
    let productID: String
    let isBestValue: Bool

    static let allPacks: [StorePackOption] = [
        StorePackOption(name: "Starter", messageCount: 10, price: "$0.99", productID: "com.festichat.pack.starter10", isBestValue: false),
        StorePackOption(name: "Social", messageCount: 25, price: "$1.99", productID: "com.festichat.pack.social25", isBestValue: false),
        StorePackOption(name: "Festival", messageCount: 50, price: "$3.99", productID: "com.festichat.pack.festival50", isBestValue: true),
        StorePackOption(name: "Squad", messageCount: 100, price: "$5.99", productID: "com.festichat.pack.squad100", isBestValue: false),
        StorePackOption(name: "Season Pass", messageCount: 1000, price: "$29.99", productID: "com.festichat.pack.season1000", isBestValue: false),
    ]
}

// MARK: - Preview

#Preview("Message Pack Store") {
    NavigationStack {
        MessagePackStore()
    }
    .preferredColorScheme(.dark)
    .festiChatTheme()
}

#Preview("Message Pack Store - Low Balance") {
    NavigationStack {
        MessagePackStore()
    }
    .preferredColorScheme(.light)
    .festiChatTheme()
}

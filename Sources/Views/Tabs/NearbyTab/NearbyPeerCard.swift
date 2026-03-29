import SwiftUI

// MARK: - NearbyPeerCard

/// Glass card displaying a nearby mesh peer or friend.
///
/// Shows avatar (initials fallback), display name, hop distance, and an
/// RSSI signal-strength indicator. Tappable with a 44pt minimum target.
struct NearbyPeerCard: View {

    let displayName: String
    let username: String?
    let avatarData: Data?
    let hopCount: Int
    let rssi: Int
    let isOnline: Bool
    let isFriend: Bool

    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: BlipSpacing.md) {
                avatarView
                peerInfo
                Spacer(minLength: 0)
                rssiIndicator
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(
            thickness: .regular,
            cornerRadius: BlipCornerRadius.xl,
            borderOpacity: 0.15
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Avatar

    private var avatarView: some View {
        ZStack {
            if let avatarData, let uiImage = uiImageFromData(avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient.blipAccent)
                    .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                    .overlay(
                        Text(initials)
                            .font(theme.typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    )
            }

            // Online indicator
            if isOnline {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(colorScheme == .dark ? Color.black : Color.white, lineWidth: 1.5)
                    )
                    .offset(x: 14, y: 14)
            }

            // Friend badge
            if isFriend {
                Circle()
                    .fill(.blipAccentPurple)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: -14, y: 14)
            }
        }
    }

    // MARK: - Peer Info

    private var peerInfo: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(displayName)
                .font(theme.typography.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.colors.text)
                .lineLimit(1)

            HStack(spacing: BlipSpacing.xs) {
                if let username {
                    Text("@\(username)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Text(hopDescription)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.colors.hover)
                    )
            }
        }
    }

    // MARK: - RSSI Indicator

    private var rssiIndicator: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: barIndex))
                    .frame(width: 3, height: barHeight(for: barIndex))
            }
        }
        .frame(width: 20, height: 16)
        .accessibilityLabel("Signal strength: \(signalDescription)")
    }

    private func barColor(for index: Int) -> Color {
        let level = signalLevel
        if index < level {
            switch level {
            case 4: return BlipColors.darkColors.statusGreen
            case 3: return BlipColors.darkColors.statusGreen
            case 2: return BlipColors.darkColors.statusAmber
            default: return BlipColors.darkColors.statusRed
            }
        }
        return theme.colors.border
    }

    private func barHeight(for index: Int) -> CGFloat {
        CGFloat(4 + index * 3)
    }

    /// Maps RSSI to 0-4 signal bars.
    private var signalLevel: Int {
        switch rssi {
        case -50...0: return 4    // Excellent
        case -65...(-51): return 3 // Good
        case -80...(-66): return 2 // Fair
        case -95...(-81): return 1 // Weak
        default: return 0          // No signal
        }
    }

    // MARK: - Helpers

    private var initials: String {
        let components = displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    private var hopDescription: String {
        switch hopCount {
        case 0: return "Direct"
        case 1: return "1 hop"
        default: return "\(hopCount) hops"
        }
    }

    private var signalDescription: String {
        switch signalLevel {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Fair"
        case 1: return "Weak"
        default: return "No signal"
        }
    }

    private var accessibilityDescription: String {
        var desc = "\(displayName)"
        if isFriend { desc += ", friend" }
        desc += ", \(hopDescription) away"
        desc += ", signal \(signalDescription)"
        if isOnline { desc += ", online" }
        return desc
    }

    private func uiImageFromData(_ data: Data) -> UIImage? {
        #if canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}

// MARK: - Preview

#Preview("Peer Card - Friend Online") {
    ZStack {
        GradientBackground()
        VStack(spacing: BlipSpacing.md) {
            NearbyPeerCard(
                displayName: "Sarah Chen",
                username: "sarahc",
                avatarData: nil,
                hopCount: 0,
                rssi: -45,
                isOnline: true,
                isFriend: true
            )

            NearbyPeerCard(
                displayName: "Jake M",
                username: "jakem",
                avatarData: nil,
                hopCount: 2,
                rssi: -72,
                isOnline: true,
                isFriend: false
            )

            NearbyPeerCard(
                displayName: "Anonymous",
                username: nil,
                avatarData: nil,
                hopCount: 5,
                rssi: -90,
                isOnline: false,
                isFriend: false
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

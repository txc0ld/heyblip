import SwiftUI

private enum AvatarViewL10n {
    static let onlineSuffix = String(localized: "common.avatar.online_suffix", defaultValue: "online")
    static let previewAlice = "Alice"
    static let previewBobSmith = "Bob Smith"
    static let previewCharlie = "Charlie"
    static let previewDana = "Dana"
    static let previewJake = "Jake"
    static let previewBob = "Bob"

    static func accessibilityLabel(name: String, isOnline: Bool) -> String {
        if isOnline {
            return String(
                format: String(localized: "common.avatar.accessibility_label_online", defaultValue: "%@ avatar, %@"),
                locale: Locale.current,
                name,
                onlineSuffix
            )
        }

        return String(
            format: String(localized: "common.avatar.accessibility_label", defaultValue: "%@ avatar"),
            locale: Locale.current,
            name
        )
    }
}

// MARK: - AvatarView

/// Circular avatar with gradient ring border.
/// - Friend: accent gradient ring
/// - Nearby: green pulse animation ring
/// - Subscriber: accent ring (always visible)
/// Falls back to initials on gradient when no image is available.
struct AvatarView: View {

    /// The relationship context that controls the ring style.
    enum RingStyle: Sendable {
        /// No ring.
        case none
        /// Accent purple gradient ring for friends.
        case friend
        /// Green pulsing ring for nearby peers.
        case nearby
        /// Accent ring for subscribers.
        case subscriber
    }

    /// Avatar image data (JPEG/PNG). When nil, falls back to remote URL then initials.
    let imageData: Data?

    /// Remote avatar URL. Used when local imageData is nil.
    let avatarURL: String?

    /// Display name used for initials fallback.
    let name: String

    /// Diameter of the avatar circle.
    let size: CGFloat

    /// Ring style around the avatar.
    let ringStyle: RingStyle

    /// Whether the avatar shows an online indicator dot.
    let showOnlineIndicator: Bool

    @State private var pulseScale: CGFloat = 1.0
    @Environment(\.colorScheme) private var colorScheme

    init(
        imageData: Data? = nil,
        avatarURL: String? = nil,
        name: String,
        size: CGFloat = BlipSizing.avatarSmall,
        ringStyle: RingStyle = .none,
        showOnlineIndicator: Bool = false
    ) {
        self.imageData = imageData
        self.avatarURL = avatarURL
        self.name = name
        self.size = size
        self.ringStyle = ringStyle
        self.showOnlineIndicator = showOnlineIndicator
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Ring + avatar stack
            ZStack {
                // Ring background
                if ringStyle != .none {
                    ringView
                }

                // Avatar circle
                avatarCircle
                    .frame(width: avatarInnerSize, height: avatarInnerSize)
            }
            .frame(width: size, height: size)

            // Online indicator
            if showOnlineIndicator {
                onlineIndicatorDot
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AvatarViewL10n.accessibilityLabel(name: name, isOnline: showOnlineIndicator))
    }

    // MARK: - Avatar Image / Initials

    @ViewBuilder
    private var avatarCircle: some View {
        if let data = imageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if let urlString = avatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                case .failure:
                    initialsFallback
                case .empty:
                    initialsFallback
                        .overlay(
                            ProgressView()
                                .tint(.white.opacity(0.6))
                        )
                @unknown default:
                    initialsFallback
                }
            }
        } else {
            initialsFallback
        }
    }

    private var initialsFallback: some View {
        Circle()
            .fill(initialsGradient)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    // MARK: - Ring

    @ViewBuilder
    private var ringView: some View {
        switch ringStyle {
        case .none:
            EmptyView()

        case .friend:
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.blipAccentPurple,
                            Color(red: 0.55, green: 0.15, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: ringWidth
                )
                .frame(width: size, height: size)

        case .nearby:
            ZStack {
                // Pulsing outer ring
                Circle()
                    .stroke(
                        Color(red: 0.20, green: 0.84, blue: 0.47).opacity(0.4),
                        lineWidth: ringWidth
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(pulseScale)
                    .opacity(2.0 - Double(pulseScale))
                    .onAppear {
                        startPulse()
                    }

                // Static inner ring
                Circle()
                    .stroke(
                        Color(red: 0.20, green: 0.84, blue: 0.47),
                        lineWidth: ringWidth
                    )
                    .frame(width: size, height: size)
            }

        case .subscriber:
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.blipAccentPurple,
                            Color(red: 0.6, green: 0.2, blue: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: ringWidth + 0.5
                )
                .frame(width: size, height: size)
        }
    }

    // MARK: - Online Indicator

    private var onlineIndicatorDot: some View {
        Circle()
            .fill(Color.blipElectricCyan)
            .frame(width: size * 0.25, height: size * 0.25)
            .overlay(
                Circle()
                    .stroke(
                        colorScheme == .dark ? Color.black : Color.white,
                        lineWidth: 2
                    )
            )
            .offset(x: -size * 0.02, y: -size * 0.02)
    }

    // MARK: - Computed

    private var avatarInnerSize: CGFloat {
        ringStyle == .none ? size : size - (ringWidth * 2 + 3)
    }

    private var ringWidth: CGFloat {
        max(2, size * 0.04)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let chars = words.compactMap(\.first)
        return chars.isEmpty
            ? String(name.prefix(1)).uppercased()
            : String(chars).uppercased()
    }

    private var initialsGradient: LinearGradient {
        // Generate a consistent gradient from the name's hash
        let hash = abs(name.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.6, brightness: 0.5),
                Color(hue: hue2, saturation: 0.5, brightness: 0.4)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Animation

    private func startPulse() {
        guard !SpringConstants.isReduceMotionEnabled else { return }
        withAnimation(
            SpringConstants.gentleAnimation
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.15
        }
    }
}

// MARK: - Preview

#Preview("Avatar - No Image") {
    HStack(spacing: 16) {
        AvatarView(name: AvatarViewL10n.previewAlice, size: 40, ringStyle: .none)
        AvatarView(name: AvatarViewL10n.previewBobSmith, size: 56, ringStyle: .friend)
        AvatarView(name: AvatarViewL10n.previewCharlie, size: 56, ringStyle: .nearby)
        AvatarView(name: AvatarViewL10n.previewDana, size: 56, ringStyle: .subscriber)
    }
    .padding()
    .background(GradientBackground())
}

#Preview("Avatar - With Online") {
    AvatarView(
        name: AvatarViewL10n.previewJake,
        size: 80,
        ringStyle: .friend,
        showOnlineIndicator: true
    )
    .padding()
    .background(GradientBackground())
}

#Preview("Avatar - Light") {
    HStack(spacing: 16) {
        AvatarView(name: AvatarViewL10n.previewAlice, size: 40, ringStyle: .none)
        AvatarView(name: AvatarViewL10n.previewBob, size: 56, ringStyle: .friend)
        AvatarView(name: AvatarViewL10n.previewCharlie, size: 56, ringStyle: .nearby, showOnlineIndicator: true)
    }
    .padding()
    .background(Color.white)
    .preferredColorScheme(.light)
}

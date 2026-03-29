import SwiftUI

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

    /// Avatar image data (JPEG/PNG). When nil, shows initials.
    let imageData: Data?

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
        name: String,
        size: CGFloat = BlipSizing.avatarSmall,
        ringStyle: RingStyle = .none,
        showOnlineIndicator: Bool = false
    ) {
        self.imageData = imageData
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) avatar")
    }

    // MARK: - Avatar Image / Initials

    @ViewBuilder
    private var avatarCircle: some View {
        if let data = imageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            // Initials fallback
            Circle()
                .fill(initialsGradient)
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
        }
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
            .fill(Color(red: 0.20, green: 0.84, blue: 0.47))
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
            .easeInOut(duration: 1.5)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.15
        }
    }
}

// MARK: - Preview

#Preview("Avatar - No Image") {
    HStack(spacing: 16) {
        AvatarView(name: "Alice", size: 40, ringStyle: .none)
        AvatarView(name: "Bob Smith", size: 56, ringStyle: .friend)
        AvatarView(name: "Charlie", size: 56, ringStyle: .nearby)
        AvatarView(name: "Dana", size: 56, ringStyle: .subscriber)
    }
    .padding()
    .background(GradientBackground())
}

#Preview("Avatar - With Online") {
    AvatarView(
        name: "Jake",
        size: 80,
        ringStyle: .friend,
        showOnlineIndicator: true
    )
    .padding()
    .background(GradientBackground())
}

#Preview("Avatar - Light") {
    HStack(spacing: 16) {
        AvatarView(name: "Alice", size: 40, ringStyle: .none)
        AvatarView(name: "Bob", size: 56, ringStyle: .friend)
        AvatarView(name: "Charlie", size: 56, ringStyle: .nearby, showOnlineIndicator: true)
    }
    .padding()
    .background(Color.white)
    .preferredColorScheme(.light)
}

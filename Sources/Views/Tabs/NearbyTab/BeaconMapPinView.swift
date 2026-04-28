import SwiftUI

private enum BeaconMapPinViewL10n {
    static let beaconAccessibility = String(
        localized: "nearby.friend_finder.beacon_accessibility_label",
        defaultValue: "Beacon: %@"
    )
}

// MARK: - BeaconMapPinView

/// Custom beacon annotation with a hexagon body, cyan tint, and pulse halo.
///
/// Visually distinct from `FriendMapPinView`:
/// - **Shape**: hexagon (vs. circle for friends) so beacons read as "place
///   markers" rather than "people" at a glance.
/// - **Tint**: `blipElectricCyan` (cool) vs. friend pins which inherit a per-
///   friend palette colour. The cool/warm split holds the design-language
///   contract: friends are warm/coloured, beacons are cool/uniform.
/// - **No avatar** (per ticket).
/// - **Label** rendered below the hexagon as a small capsule chip.
///
/// Pulse halo is a hexagon stroke that scales + fades on a 1.5s loop. Honours
/// `SpringConstants.isReduceMotionEnabled` and falls back to a static stroke
/// when reduce-motion is on.
struct BeaconMapPinView: View {

    let beacon: BeaconPin

    @Environment(\.theme) private var theme
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: BlipSpacing.xxs) {
            ZStack {
                // Pulse halo — hexagon stroke that expands and fades.
                if !SpringConstants.isReduceMotionEnabled {
                    HexagonShape()
                        .stroke(Color.blipElectricCyan.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                        .scaleEffect(isPulsing ? 1.6 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.6)
                }

                // Filled hexagon body.
                HexagonShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blipElectricCyan,
                                Color.blipElectricCyan.opacity(0.65)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay(
                        HexagonShape()
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "mappin")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Color.blipElectricCyan.opacity(0.4), radius: 4)
            }

            Text(beacon.label)
                .font(theme.typography.micro)
                .foregroundStyle(.white)
                .padding(.horizontal, BlipSpacing.xs)
                .padding(.vertical, BlipSpacing.xxs)
                .background(Capsule().fill(Color.blipElectricCyan.opacity(0.85)))
                .lineLimit(1)
        }
        .accessibilityLabel(
            String(
                format: BeaconMapPinViewL10n.beaconAccessibility,
                locale: Locale.current,
                beacon.label
            )
        )
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled else { return }
            // Ambient halo — easeInOut, no autoreverse so each cycle starts
            // tight and grows out.
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Hexagon Shape

/// Regular 6-sided hexagon, point-up, inscribed in the bounding rect.
struct HexagonShape: Shape {

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2

        var path = Path()
        for index in 0..<6 {
            // Start at top (-pi/2), step pi/3 around the circle.
            let angle = (Double(index) / 6.0) * 2 * .pi - .pi / 2
            let x = cx + r * CGFloat(cos(angle))
            let y = cy + r * CGFloat(sin(angle))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview("BeaconMapPinView") {
    ZStack {
        Color.gray.ignoresSafeArea()
        VStack(spacing: 60) {
            BeaconMapPinView(
                beacon: BeaconPin(
                    id: UUID(),
                    label: "I'm here!",
                    coordinate: .init(latitude: 51, longitude: -2),
                    createdBy: "You",
                    expiresAt: Date().addingTimeInterval(1_800)
                )
            )
            BeaconMapPinView(
                beacon: BeaconPin(
                    id: UUID(),
                    label: "Food village",
                    coordinate: .init(latitude: 51, longitude: -2),
                    createdBy: "Sarah",
                    expiresAt: Date().addingTimeInterval(900)
                )
            )
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("BeaconMapPinView — light") {
    ZStack {
        Color.white.ignoresSafeArea()
        BeaconMapPinView(
            beacon: BeaconPin(
                id: UUID(),
                label: "Stage 2",
                coordinate: .init(latitude: 51, longitude: -2),
                createdBy: "You",
                expiresAt: Date().addingTimeInterval(1_800)
            )
        )
    }
    .preferredColorScheme(.light)
}

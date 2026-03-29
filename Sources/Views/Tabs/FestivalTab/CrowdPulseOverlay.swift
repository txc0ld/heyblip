import SwiftUI
import MapKit

// MARK: - CrowdPulseOverlay

/// Heatmap overlay rendered on top of the stage map.
///
/// Color-coded density visualization:
/// - Quiet (blue): few people
/// - Moderate (green): comfortable crowd
/// - Busy (orange): getting crowded
/// - Packed (red): very dense
///
/// Computed from mesh peer density per geohash-7 cell.
struct CrowdPulseOverlay: View {

    let pulseData: [CrowdPulseCell]
    let mapRegion: MKCoordinateRegion

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            Canvas { context, canvasSize in
                for cell in pulseData {
                    let normalizedX = normalizeX(cell.coordinate, in: mapRegion)
                    let normalizedY = normalizeY(cell.coordinate, in: mapRegion)

                    let centerX = normalizedX * size.width
                    let centerY = normalizedY * size.height
                    let radius = cellRadius(for: cell, in: size)

                    let gradient = Gradient(colors: [
                        heatColor(for: cell.level).opacity(0.5),
                        heatColor(for: cell.level).opacity(0.2),
                        heatColor(for: cell.level).opacity(0.0),
                    ])

                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: centerX - radius,
                            y: centerY - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .radialGradient(
                            gradient,
                            center: CGPoint(x: centerX, y: centerY),
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }
            .blendMode(.screen)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Color Mapping

    private func heatColor(for level: HeatLevel) -> Color {
        switch level {
        case .quiet: return Color(red: 0.2, green: 0.4, blue: 1.0)    // Blue
        case .moderate: return Color(red: 0.2, green: 0.8, blue: 0.3) // Green
        case .busy: return Color(red: 1.0, green: 0.6, blue: 0.1)     // Orange
        case .packed: return Color(red: 1.0, green: 0.2, blue: 0.2)   // Red
        }
    }

    // MARK: - Coordinate Normalization

    private func normalizeX(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion) -> CGFloat {
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        let normalized = (coordinate.longitude - minLon) / (maxLon - minLon)
        return CGFloat(max(0, min(1, normalized)))
    }

    private func normalizeY(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion) -> CGFloat {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        // Invert Y: higher latitude = top of view
        let normalized = 1.0 - (coordinate.latitude - minLat) / (maxLat - minLat)
        return CGFloat(max(0, min(1, normalized)))
    }

    private func cellRadius(for cell: CrowdPulseCell, in size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.08
        let multiplier: CGFloat
        switch cell.level {
        case .quiet: multiplier = 1.0
        case .moderate: multiplier = 1.2
        case .busy: multiplier = 1.4
        case .packed: multiplier = 1.6
        }
        return base * multiplier
    }
}

// MARK: - CrowdPulseCell

/// View-level data for a single heatmap cell.
struct CrowdPulseCell: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let level: HeatLevel
    let peerCount: Int
    let geohash: String
}

// MARK: - CrowdPulseLegend

/// Legend overlay explaining heatmap colors.
struct CrowdPulseLegend: View {

    @Environment(\.theme) private var theme

    var body: some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.md, padding: .blipContent) {
            HStack(spacing: BlipSpacing.md) {
                legendItem(color: Color(red: 0.2, green: 0.4, blue: 1.0), label: "Quiet")
                legendItem(color: Color(red: 0.2, green: 0.8, blue: 0.3), label: "Moderate")
                legendItem(color: Color(red: 1.0, green: 0.6, blue: 0.1), label: "Busy")
                legendItem(color: Color(red: 1.0, green: 0.2, blue: 0.2), label: "Packed")
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: BlipSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) crowd density")
    }
}

// MARK: - Preview

#Preview("Crowd Pulse Overlay") {
    let cells: [CrowdPulseCell] = [
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), level: .packed, peerCount: 320, geohash: "gcpu2e1"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845), level: .busy, peerCount: 180, geohash: "gcpu2e2"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0038, longitude: -2.5870), level: .moderate, peerCount: 80, geohash: "gcpu2e3"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0060, longitude: -2.5830), level: .quiet, peerCount: 15, geohash: "gcpu2e4"),
    ]

    let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
        latitudinalMeters: 3000,
        longitudinalMeters: 3000
    )

    VStack(spacing: BlipSpacing.md) {
        CrowdPulseOverlay(pulseData: cells, mapRegion: region)
            .frame(height: 300)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl))

        CrowdPulseLegend()
    }
    .padding()
    .background(GradientBackground())
    .preferredColorScheme(.dark)
}

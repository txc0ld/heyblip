import SwiftUI

// MARK: - AvatarCropView

/// Circular crop editor for avatar images.
///
/// Supports pinch-to-zoom and pan gestures. Shows a circular preview
/// overlay with dimmed out-of-bounds region. Confirm/cancel actions.
struct AvatarCropView: View {

    @Binding var isPresented: Bool
    var onCrop: ((CGRect) -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var imageSize: CGSize = CGSize(width: 300, height: 300)

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let cropCircleSize: CGFloat = 280
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: BlipSpacing.lg) {
                    Spacer()
                    cropArea
                    instructions
                    actionButtons
                    Spacer()
                }
            }
            .navigationTitle("Crop Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Crop Area

    private var cropArea: some View {
        ZStack {
            // Placeholder image (in production, use the actual selected image)
            LinearGradient(
                colors: [.blipGradientDeepPurple, .blipGradientMidnightBlue, .blipGradientDarkTeal],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: imageSize.width * scale, height: imageSize.height * scale)
            .offset(offset)
            .overlay(
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.3))
                    .offset(offset)
            )

            // Dimmed overlay with circular cutout
            CropMask(circleSize: cropCircleSize)
                .fill(.black.opacity(0.6))
                .allowsHitTesting(false)

            // Circle border
            Circle()
                .stroke(.white.opacity(0.6), lineWidth: 2)
                .frame(width: cropCircleSize, height: cropCircleSize)
                .allowsHitTesting(false)

            // Grid lines (thirds)
            cropGridLines
                .allowsHitTesting(false)
        }
        .frame(width: cropCircleSize + 40, height: cropCircleSize + 40)
        .clipShape(Rectangle())
        .gesture(panGesture)
        .gesture(pinchGesture)
        .accessibilityLabel("Crop area. Pinch to zoom, drag to reposition.")
    }

    // MARK: - Grid Lines

    private var cropGridLines: some View {
        let radius = cropCircleSize / 2
        return ZStack {
            // Horizontal thirds
            ForEach([1, 2], id: \.self) { i in
                let y = -radius + (cropCircleSize / 3) * CGFloat(i)
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: cropCircleSize * 0.8, height: 0.5)
                    .offset(y: y)
            }

            // Vertical thirds
            ForEach([1, 2], id: \.self) { i in
                let x = -radius + (cropCircleSize / 3) * CGFloat(i)
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 0.5, height: cropCircleSize * 0.8)
                    .offset(x: x)
            }
        }
        .clipShape(Circle().size(CGSize(width: cropCircleSize, height: cropCircleSize))
                        .offset(x: -cropCircleSize / 2, y: -cropCircleSize / 2))
    }

    // MARK: - Instructions

    private var instructions: some View {
        Text("Pinch to zoom, drag to reposition")
            .font(theme.typography.secondary)
            .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: BlipSpacing.lg) {
            GlassButton("Reset", icon: "arrow.counterclockwise", style: .secondary) {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                }
            }

            GlassButton("Confirm", icon: "checkmark", style: .primary) {
                let cropRect = calculateCropRect()
                onCrop?(cropRect)
                isPresented = false
            }
        }
        .padding(.horizontal, BlipSpacing.xl)
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
                clampOffset()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = max(minScale, min(maxScale, newScale))
            }
            .onEnded { _ in
                lastScale = scale
                clampOffset()
            }
    }

    // MARK: - Helpers

    private func clampOffset() {
        let maxOffsetX = max(0, (imageSize.width * scale - cropCircleSize) / 2)
        let maxOffsetY = max(0, (imageSize.height * scale - cropCircleSize) / 2)

        withAnimation(SpringConstants.accessiblePageEntrance) {
            offset = CGSize(
                width: max(-maxOffsetX, min(maxOffsetX, offset.width)),
                height: max(-maxOffsetY, min(maxOffsetY, offset.height))
            )
        }
        lastOffset = offset
    }

    private func calculateCropRect() -> CGRect {
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        let cropX = (scaledWidth / 2 - offset.width - cropCircleSize / 2) / scaledWidth
        let cropY = (scaledHeight / 2 - offset.height - cropCircleSize / 2) / scaledHeight
        let cropSize = cropCircleSize / scaledWidth

        return CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)
    }
}

// MARK: - CropMask

/// Shape that creates a rectangular mask with a circular cutout.
private struct CropMask: Shape {
    let circleSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let circlePath = Path(ellipseIn: CGRect(
            x: rect.midX - circleSize / 2,
            y: rect.midY - circleSize / 2,
            width: circleSize,
            height: circleSize
        ))
        path.addPath(circlePath)
        return path
    }

    var style: FillStyle {
        FillStyle(eoFill: true)
    }
}

// MARK: - Preview

#Preview("Avatar Crop") {
    AvatarCropView(isPresented: .constant(true))
        .preferredColorScheme(.dark)
        .blipTheme()
}

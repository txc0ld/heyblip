import SwiftUI

private enum ImageViewerL10n {
    static let unavailable = String(localized: "chat.image_viewer.unavailable", defaultValue: "Image unavailable")
    static let close = String(localized: "common.close", defaultValue: "Close")
    static let share = String(localized: "chat.image_viewer.share", defaultValue: "Share image")
}

// MARK: - ImageViewer

/// Full-screen image viewer with pinch-to-zoom and swipe-down-to-dismiss.
struct ImageViewer: View {

    /// The image data to display.
    let imageData: Data?

    /// Dismiss binding.
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffset: CGFloat = 0
    @State private var backgroundOpacity: Double = 1.0

    @Environment(\.theme) private var theme

    /// Threshold for swipe dismiss (points).
    private let dismissThreshold: CGFloat = 150

    var body: some View {
        ZStack {
            // Dark background
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Image
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dragOffset)
                    .gesture(zoomGesture)
                    .gesture(panGesture)
                    .simultaneousGesture(dismissDragGesture)
            } else {
                VStack(spacing: BlipSpacing.md) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(ImageViewerL10n.unavailable)
                        .font(theme.typography.secondary)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Top bar with close and share buttons
            VStack {
                HStack {
                    closeButton
                    Spacer()
                    shareButton
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.top, BlipSpacing.sm)

                Spacer()
            }
        }
        .statusBarHidden()
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .blipTextStyle(.callout)
                .foregroundStyle(.white)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ImageViewerL10n.close)
    }

    // MARK: - Share Button

    @ViewBuilder
    private var shareButton: some View {
        if let data = imageData, let uiImage = UIImage(data: data) {
            let transferable = Image(uiImage: uiImage)
            ShareLink(
                item: transferable,
                preview: SharePreview(
                    ImageViewerL10n.share,
                    image: transferable
                )
            ) {
                Image(systemName: "square.and.arrow.up")
                    .blipTextStyle(.callout)
                    .foregroundStyle(.white)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ImageViewerL10n.share)
        }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = max(1.0, min(newScale, 5.0))
            }
            .onEnded { value in
                lastScale = scale
                if scale < 1.0 {
                    withAnimation(SpringConstants.gentleAnimation) {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard scale <= 1.0 else { return }
                let verticalDrag = value.translation.height
                if verticalDrag > 0 {
                    dragOffset = verticalDrag
                    backgroundOpacity = max(0.3, 1.0 - Double(verticalDrag / 400))
                }
            }
            .onEnded { value in
                guard scale <= 1.0 else { return }
                if value.translation.height > dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(SpringConstants.gentleAnimation) {
                        dragOffset = 0
                        backgroundOpacity = 1.0
                    }
                }
            }
    }

    // MARK: - Dismiss

    private func dismiss() {
        if SpringConstants.isReduceMotionEnabled {
            isPresented = false
        } else {
            withAnimation(SpringConstants.gentleAnimation) {
                backgroundOpacity = 0
                dragOffset = 300
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isPresented = false
            }
        }
    }
}

// MARK: - Preview

#Preview("Image Viewer") {
    struct ViewerPreview: View {
        @State private var isPresented = true
        var body: some View {
            ZStack {
                Color.gray.ignoresSafeArea()
                Text("Background content")
                    .foregroundStyle(.white)
            }
            .fullScreenCover(isPresented: $isPresented) {
                ImageViewer(imageData: nil, isPresented: $isPresented)
            }
        }
    }
    return ViewerPreview()
}

#Preview("Image Viewer - Inline") {
    ImageViewer(imageData: nil, isPresented: .constant(true))
}

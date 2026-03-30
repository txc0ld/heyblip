import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - QRCodeSheet

/// Displays a QR code containing the user's username for easy profile sharing.
/// Other users can scan this to send a friend request.
struct QRCodeSheet: View {

    let user: User

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: BlipSpacing.lg) {
            // Header
            HStack {
                Text("My QR Code")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.top, BlipSpacing.md)

            // QR Code card
            VStack(spacing: BlipSpacing.md) {
                // QR code image
                if let qrImage = generateQRCode(for: "blip://user/\(user.username)") {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
                        .padding(BlipSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                                .fill(.white)
                        )
                }

                // User info
                HStack(spacing: BlipSpacing.sm) {
                    if user.isVerified {
                        ZStack {
                            Circle()
                                .fill(.blue)
                                .frame(width: 18, height: 18)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    Text("@\(user.username)")
                        .font(.custom(BlipFontName.semiBold, size: 18, relativeTo: .headline))
                        .foregroundStyle(theme.colors.text)
                }

                Text("Scan to add me on Blip")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity)

            // Share button
            if let qrImage = generateQRCode(for: "blip://user/\(user.username)") {
                ShareLink(
                    item: Image(uiImage: qrImage),
                    preview: SharePreview("My Blip QR Code", image: Image(uiImage: qrImage))
                ) {
                    HStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                        Text("Share QR Code")
                            .font(theme.typography.body)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.sm)
                    .background(
                        Capsule()
                            .fill(LinearGradient.blipAccent)
                    )
                }
                .padding(.horizontal, BlipSpacing.xl)
                .frame(minHeight: BlipSizing.minTapTarget)
            }

            Spacer()
        }
    }

    // MARK: - QR Code Generation

    private func generateQRCode(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Tint the QR code with brand purple
        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = scaledImage
        colorFilter.color0 = CIColor(color: UIColor(named: "AccentPurple") ?? UIColor(red: 0.4, green: 0, blue: 1, alpha: 1))
        colorFilter.color1 = CIColor.white

        guard let tintedImage = colorFilter.outputImage,
              let cgImage = context.createCGImage(tintedImage, from: tintedImage.extent) else {
            // Fallback: black and white
            guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Preview

#Preview("QR Code Sheet") {
    QRCodeSheet(
        user: User(
            username: "tay",
            displayName: "Tay",
            emailHash: "abc123",
            noisePublicKey: Data(),
            signingPublicKey: Data(),
            isVerified: true
        )
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

import SwiftUI
import CoreImage.CIFilterBuiltins

private enum QRCodeSheetL10n {
    static let title = String(localized: "profile.qr_code.title", defaultValue: "My QR Code")
    static let close = String(localized: "common.close", defaultValue: "Close")
    static let subtitle = String(localized: "profile.qr_code.subtitle", defaultValue: "Scan to add me on HeyBlip")
    static let shareTitle = String(localized: "profile.qr_code.share_title", defaultValue: "My HeyBlip QR Code")
    static let shareCTA = String(localized: "profile.qr_code.share_cta", defaultValue: "Share QR Code")
    static let scanCTA = String(localized: "profile.qr_code.scan_cta", defaultValue: "Scan a QR Code")
    static let scanAccessibility = String(localized: "profile.qr_code.scan.accessibility", defaultValue: "Scan someone else's QR code")
}

// MARK: - QRCodeSheet

/// Displays a QR code containing the user's username for easy profile sharing.
/// Other users can scan this to send a friend request.
struct QRCodeSheet: View {

    let user: User

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showScanner = false
    @State private var showAddFriend = false
    @State private var scannedUsername = ""

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(theme.colors.mutedText.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, BlipSpacing.sm)

            // Header
            HStack {
                Text(QRCodeSheetL10n.title)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(QRCodeSheetL10n.close)
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.top, BlipSpacing.sm)

            Spacer().frame(height: BlipSpacing.lg)

            // QR Code card — centered and contained
            VStack(spacing: BlipSpacing.md) {
                if let qrImage = generateQRCode(for: "heyblip://user/\(user.username)") {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
                        .padding(BlipSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                                .fill(.white)
                        )
                }

                // User info
                HStack(spacing: BlipSpacing.xs) {
                    if user.isVerified {
                        VerifiedBadge(size: 18)
                    }

                    Text("@\(user.username)")
                        .font(.custom(BlipFontName.semiBold, size: 18, relativeTo: .headline))
                        .foregroundStyle(theme.colors.text)
                }

                Text(QRCodeSheetL10n.subtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(.horizontal, BlipSpacing.lg)

            Spacer().frame(height: BlipSpacing.lg)

            // Share button
            if let qrImage = generateQRCode(for: "heyblip://user/\(user.username)") {
                ShareLink(
                    item: Image(uiImage: qrImage),
                    preview: SharePreview(QRCodeSheetL10n.shareTitle, image: Image(uiImage: qrImage))
                ) {
                    HStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                        Text(QRCodeSheetL10n.shareCTA)
                            .font(theme.typography.body)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.sm + 2)
                    .background(
                        Capsule()
                            .fill(LinearGradient.blipAccent)
                    )
                }
                .padding(.horizontal, BlipSpacing.lg)
                .frame(minHeight: BlipSizing.minTapTarget)
            }

            // Scan QR button
            Button(action: { showScanner = true }) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 14, weight: .medium))
                    Text(QRCodeSheetL10n.scanCTA)
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                }
                .foregroundStyle(theme.colors.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BlipSpacing.sm + 2)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: BlipSizing.hairline)
                )
            }
            .padding(.horizontal, BlipSpacing.lg)
            .frame(minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(QRCodeSheetL10n.scanAccessibility)

            Spacer()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { username in
                scannedUsername = username
                showAddFriend = true
            }
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendByUsernameSheet(initialUsername: scannedUsername)
        }
    }

    // MARK: - QR Code Generation

    private func generateQRCode(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = scaledImage
        colorFilter.color0 = CIColor(color: UIColor(red: 0.4, green: 0, blue: 1, alpha: 1))
        colorFilter.color1 = CIColor.white

        guard let tintedImage = colorFilter.outputImage,
              let cgImage = context.createCGImage(tintedImage, from: tintedImage.extent) else {
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

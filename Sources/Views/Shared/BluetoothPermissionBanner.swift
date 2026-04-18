import SwiftUI

private enum BluetoothPermissionBannerL10n {
    static let title = String(localized: "common.bluetooth.permission.title", defaultValue: "Bluetooth is required for mesh chat")
    static let subtitle = String(localized: "common.bluetooth.permission.subtitle", defaultValue: "Tap to open Settings")
    static let accessibilityLabel = String(localized: "common.bluetooth.permission.accessibility_label", defaultValue: "Enable Bluetooth in Settings")
}

// MARK: - BluetoothPermissionBanner

/// Full-width banner shown when Bluetooth permission is denied.
/// Taps open the system Settings app so the user can re-enable Bluetooth.
struct BluetoothPermissionBanner: View {

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(theme.typography.title3)
                    .foregroundStyle(Color.blipAccentPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(BluetoothPermissionBannerL10n.title)
                        .font(.custom(BlipFontName.semiBold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(theme.colors.text)

                    Text(BluetoothPermissionBannerL10n.subtitle)
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.blipAccentPurple.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BluetoothPermissionBannerL10n.accessibilityLabel)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

#Preview("Bluetooth Permission Banner") {
    VStack {
        BluetoothPermissionBanner()
            .padding()
        Spacer()
    }
    .background(Color.black)
    .environment(\.theme, Theme.shared)
}

import SwiftUI

// MARK: - BluetoothPermissionBanner

/// Full-width banner shown when Bluetooth permission is denied.
/// Taps open the system Settings app so the user can re-enable Bluetooth.
struct BluetoothPermissionBanner: View {

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color("AccentPurple"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluetooth is required for mesh chat")
                        .font(.custom(BlipFontName.semiBold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(theme.colors.text)

                    Text("Tap to open Settings")
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color("AccentPurple").opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enable Bluetooth in Settings")
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
    .background(Color("Background"))
    .environment(\.theme, Theme.shared)
}

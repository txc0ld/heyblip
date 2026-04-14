import SwiftUI
import CoreBluetooth

private enum PermissionsStepL10n {
    static let title = String(localized: "onboarding.permissions.title", defaultValue: "Stay connected\nwithout signal")
    static let subtitle = String(localized: "onboarding.permissions.subtitle", defaultValue: "HeyBlip needs Bluetooth to connect with people nearby. Your device becomes part of a mesh network that relays messages.")
    static let bluetoothEnabled = String(localized: "onboarding.permissions.enabled", defaultValue: "Bluetooth enabled")
    static let bluetoothRequired = String(localized: "onboarding.permissions.required_message", defaultValue: "Bluetooth is required for HeyBlip to work.")
    static let openSettings = String(localized: "common.open_settings", defaultValue: "Open Settings")
    static let openSettingsHint = String(localized: "onboarding.permissions.open_settings.hint", defaultValue: "Opens the iOS Settings app for HeyBlip.")
    static let getStarted = String(localized: "onboarding.permissions.cta.get_started", defaultValue: "Get started")
    static let enableBluetooth = String(localized: "onboarding.permissions.cta.enable_bluetooth", defaultValue: "Enable Bluetooth")
    static let completeHint = String(localized: "onboarding.permissions.complete.hint", defaultValue: "Finishes onboarding and opens the app.")
    static let requestHint = String(localized: "onboarding.permissions.request.hint", defaultValue: "Requests Bluetooth permission from iOS.")
    static let requiredCaption = String(localized: "onboarding.permissions.required_caption", defaultValue: "Required for HeyBlip to work")
}

// MARK: - BLE Permission Observer

/// Delegate that keeps the CBCentralManager alive and forwards state changes.
private final class BLEPermissionObserver: NSObject, CBCentralManagerDelegate {
    var onStateChange: ((CBManagerAuthorization) -> Void)?
    private(set) var manager: CBCentralManager?

    func startRequest() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(CBManager.authorization)
    }
}

// MARK: - PermissionsStep

/// Onboarding step 3: Bluetooth permission request.
/// BLE permission is ONLY requested when the user taps "Enable Bluetooth".
/// No auto-advance — user must tap "Get started" to complete onboarding.
struct PermissionsStep: View {

    /// Called when the user taps "Get started" after granting permission.
    var onComplete: () -> Void = {}

    /// Whether this step is the currently visible tab.
    /// Guards onAppear logic so TabView pre-rendering doesn't trigger side effects.
    var isActive = false

    @State private var contentVisible = false
    @State private var permissionGranted = false
    @State private var permissionDenied = false
    @State private var observer = BLEPermissionObserver()
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Illustration
            illustrationSection

            Spacer()
                .frame(height: BlipSpacing.xxl)

            // Text
            VStack(spacing: BlipSpacing.md) {
                Text(PermissionsStepL10n.title)
                    .font(theme.typography.largeTitle)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(PermissionsStepL10n.subtitle)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, BlipSpacing.xl)

            Spacer()
                .frame(height: BlipSpacing.lg)

            // Permission status
            if permissionGranted {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.colors.statusGreen)
                        .accessibilityLabel(PermissionsStepL10n.bluetoothEnabled)
                    Text(PermissionsStepL10n.bluetoothEnabled)
                        .font(.custom(BlipFontName.medium, size: 15, relativeTo: .body))
                        .foregroundStyle(theme.colors.statusGreen)
                }
                .padding(.bottom, BlipSpacing.md)
            }

            if permissionDenied {
                VStack(spacing: BlipSpacing.sm) {
                    Text(PermissionsStepL10n.bluetoothRequired)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.statusAmber)
                        .multilineTextAlignment(.center)

                    Button {
                        openSettings()
                    } label: {
                        Text(PermissionsStepL10n.openSettings)
                            .font(.custom(BlipFontName.medium, size: 14, relativeTo: .footnote))
                            .foregroundStyle(Color.blipAccentPurple)
                            .accessibilityAddTraits(.isButton)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityHint(PermissionsStepL10n.openSettingsHint)
                }
                .padding(.horizontal, BlipSpacing.xl)
                .padding(.bottom, BlipSpacing.md)
            }

            Spacer()

            // Action buttons
            VStack(spacing: BlipSpacing.md) {
                GlassButton(
                    permissionGranted ? PermissionsStepL10n.getStarted : PermissionsStepL10n.enableBluetooth,
                    icon: permissionGranted ? "arrow.right" : "antenna.radiowaves.left.and.right"
                ) {
                    if permissionGranted {
                        onComplete()
                    } else {
                        requestBluetoothPermission()
                    }
                }
                .fullWidth()
                .accessibilityHint(permissionGranted ? PermissionsStepL10n.completeHint : PermissionsStepL10n.requestHint)

                if !permissionGranted && !permissionDenied {
                    Text(PermissionsStepL10n.requiredCaption)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
            .padding(.horizontal, BlipSpacing.lg)
            .padding(.bottom, BlipSpacing.xl)
        }
        .opacity(contentVisible ? 1.0 : 0.0)
        .offset(y: contentVisible ? 0 : 15)
        .onChange(of: isActive) { _, active in
            guard active else { return }
            withAnimation(SpringConstants.accessiblePageEntrance) {
                contentVisible = true
            }
            refreshPermissionStatus()
        }
    }

    // MARK: - Illustration

    private var illustrationSection: some View {
        ZStack {
            // Background glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.blipAccentPurple.opacity(0.2),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)

            // Bluetooth icon with mesh nodes
            ZStack {
                // Outer ring nodes
                ForEach(0..<6, id: \.self) { index in
                    let angle = Angle.degrees(Double(index) * 60)
                    let radius: CGFloat = 60
                    Circle()
                        .fill(Color.blipAccentPurple.opacity(0.4))
                        .frame(width: 10, height: 10)
                        .offset(
                            x: cos(angle.radians) * radius,
                            y: sin(angle.radians) * radius
                        )
                }

                // Inner ring nodes
                ForEach(0..<3, id: \.self) { index in
                    let angle = Angle.degrees(Double(index) * 120 + 30)
                    let radius: CGFloat = 35
                    Circle()
                        .fill(Color.blipAccentPurple.opacity(0.6))
                        .frame(width: 14, height: 14)
                        .offset(
                            x: cos(angle.radians) * radius,
                            y: sin(angle.radians) * radius
                        )
                }

                // Center Bluetooth icon
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.blipAccentPurple)
            }
        }
    }

    // MARK: - Bluetooth Permission

    /// Read-only status check — never creates a CBCentralManager, never triggers a dialog.
    private func refreshPermissionStatus() {
        let authorization = CBManager.authorization
        withAnimation(SpringConstants.accessiblePageEntrance) {
            switch authorization {
            case .allowedAlways:
                permissionGranted = true
                permissionDenied = false
            case .denied, .restricted:
                permissionDenied = true
                permissionGranted = false
            default:
                break
            }
        }
    }

    /// Creates a CBCentralManager to trigger the system permission dialog.
    /// Only called on explicit user tap.
    private func requestBluetoothPermission() {
        observer.onStateChange = { authorization in
            withAnimation(SpringConstants.accessiblePageEntrance) {
                switch authorization {
                case .allowedAlways:
                    permissionGranted = true
                    permissionDenied = false
                case .denied, .restricted:
                    permissionDenied = true
                    permissionGranted = false
                default:
                    break
                }
            }
        }
        observer.startRequest()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

#Preview("Permissions Step") {
    ZStack {
        GradientBackground()
            .ignoresSafeArea()
        PermissionsStep(isActive: true)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Permissions Step - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        PermissionsStep(isActive: true)
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

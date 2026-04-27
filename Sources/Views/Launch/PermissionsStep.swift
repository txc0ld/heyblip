import SwiftUI
import CoreBluetooth
import AVFoundation
import UserNotifications

private enum PermissionsStepL10n {
    static let title = String(localized: "onboarding.permissions.title", defaultValue: "Stay connected\nwithout signal")
    static let subtitle = String(localized: "onboarding.permissions.subtitle", defaultValue: "HeyBlip needs Bluetooth to connect. Notifications keep you alerted to messages and SOS. The microphone enables voice notes.")
    static let bluetoothEnabled = String(localized: "onboarding.permissions.enabled", defaultValue: "Bluetooth enabled")
    static let microphoneEnabled = String(localized: "onboarding.permissions.microphone_enabled", defaultValue: "Microphone enabled")
    static let microphoneSkipped = String(localized: "onboarding.permissions.microphone_skipped", defaultValue: "Microphone disabled — voice notes won't work")
    static let notificationsEnabled = String(localized: "onboarding.permissions.notifications_enabled", defaultValue: "Notifications enabled")
    static let notificationsSkipped = String(localized: "onboarding.permissions.notifications_skipped", defaultValue: "Notifications disabled — DMs and SOS won't alert you")
    static let bluetoothRequired = String(localized: "onboarding.permissions.required_message", defaultValue: "Bluetooth is required for HeyBlip to work.")
    static let openSettings = String(localized: "common.open_settings", defaultValue: "Open Settings")
    static let openSettingsHint = String(localized: "onboarding.permissions.open_settings.hint", defaultValue: "Opens the iOS Settings app for HeyBlip.")
    static let getStarted = String(localized: "onboarding.permissions.cta.get_started", defaultValue: "Get started")
    static let enablePermissions = String(localized: "onboarding.permissions.cta.enable_permissions", defaultValue: "Enable permissions")
    static let completeHint = String(localized: "onboarding.permissions.complete.hint", defaultValue: "Finishes onboarding and opens the app.")
    static let requestHint = String(localized: "onboarding.permissions.request.hint", defaultValue: "Requests Bluetooth, microphone, and notification permissions from iOS.")
    static let requiredCaption = String(localized: "onboarding.permissions.required_caption", defaultValue: "Bluetooth required • Mic + notifications optional")
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
    @State private var microphoneGranted = false
    @State private var microphoneDenied = false
    @State private var notificationGranted = false
    @State private var notificationDenied = false
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
                VStack(spacing: BlipSpacing.xs) {
                    HStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.colors.statusGreen)
                            .accessibilityLabel(PermissionsStepL10n.bluetoothEnabled)
                        Text(PermissionsStepL10n.bluetoothEnabled)
                            .font(.custom(BlipFontName.medium, size: 15, relativeTo: .body))
                            .foregroundStyle(theme.colors.statusGreen)
                    }

                    if microphoneGranted {
                        HStack(spacing: BlipSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.colors.statusGreen)
                                .accessibilityLabel(PermissionsStepL10n.microphoneEnabled)
                            Text(PermissionsStepL10n.microphoneEnabled)
                                .font(.custom(BlipFontName.medium, size: 15, relativeTo: .body))
                                .foregroundStyle(theme.colors.statusGreen)
                        }
                    } else if microphoneDenied {
                        Text(PermissionsStepL10n.microphoneSkipped)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)
                    }

                    if notificationGranted {
                        HStack(spacing: BlipSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.colors.statusGreen)
                                .accessibilityLabel(PermissionsStepL10n.notificationsEnabled)
                            Text(PermissionsStepL10n.notificationsEnabled)
                                .font(.custom(BlipFontName.medium, size: 15, relativeTo: .body))
                                .foregroundStyle(theme.colors.statusGreen)
                        }
                    } else if notificationDenied {
                        Text(PermissionsStepL10n.notificationsSkipped)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)
                    }
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
                    permissionGranted ? PermissionsStepL10n.getStarted : PermissionsStepL10n.enablePermissions,
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

        // Microphone is decided independently of Bluetooth — surface its
        // current state so a user who already accepted/denied previously sees
        // the right checkmark on this screen.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneGranted = true
            microphoneDenied = false
        case .denied:
            microphoneGranted = false
            microphoneDenied = true
        case .undetermined:
            microphoneGranted = false
            microphoneDenied = false
        @unknown default:
            break
        }

        // Same for notifications — show prior state if the user already
        // answered iOS's prompt on a previous run.
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            withAnimation(SpringConstants.accessiblePageEntrance) {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    notificationGranted = true
                    notificationDenied = false
                case .denied:
                    notificationGranted = false
                    notificationDenied = true
                case .notDetermined:
                    notificationGranted = false
                    notificationDenied = false
                @unknown default:
                    break
                }
            }
        }
    }

    /// Creates a CBCentralManager to trigger the system permission dialog.
    /// Only called on explicit user tap. Once Bluetooth is granted (or denied)
    /// we chain into the microphone request so the user sees both system
    /// dialogs in sequence and isn't stuck with a greyed-out mic button later.
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
                    return
                }
            }
            requestMicrophonePermission()
        }
        observer.startRequest()
    }

    /// Trigger the iOS microphone permission dialog. Idempotent: iOS only
    /// shows the prompt the first time per install. Microphone is optional —
    /// "Get started" stays enabled regardless of the outcome. Chains into
    /// the notification permission request once a decision has been recorded.
    private func requestMicrophonePermission() {
        // Skip if iOS has already recorded an answer.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            withAnimation(SpringConstants.accessiblePageEntrance) {
                microphoneGranted = true
                microphoneDenied = false
            }
            requestNotificationPermission()
            return
        case .denied:
            withAnimation(SpringConstants.accessiblePageEntrance) {
                microphoneGranted = false
                microphoneDenied = true
            }
            requestNotificationPermission()
            return
        case .undetermined:
            break
        @unknown default:
            return
        }

        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    microphoneGranted = granted
                    microphoneDenied = !granted
                }
                requestNotificationPermission()
            }
        }
    }

    /// Trigger the iOS notification permission dialog. Last in the
    /// onboarding chain — Bluetooth → Microphone → Notifications. Optional;
    /// "Get started" stays enabled regardless of the outcome. Idempotent
    /// when iOS already has an answer recorded.
    private func requestNotificationPermission() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            // If iOS has already recorded a decision, surface it without
            // re-prompting. Skipping the request also avoids a second cold
            // dialog for users who answered on a previous run.
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    notificationGranted = true
                    notificationDenied = false
                }
                return
            case .denied:
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    notificationGranted = false
                    notificationDenied = true
                }
                return
            case .notDetermined:
                break
            @unknown default:
                return
            }

            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .badge, .sound, .providesAppNotificationSettings]
                )
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    notificationGranted = granted
                    notificationDenied = !granted
                }
            } catch {
                await DebugLogger.shared.log(
                    "PUSH",
                    "Onboarding notification request failed: \(error.localizedDescription)",
                    isError: true
                )
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    notificationDenied = true
                }
            }
        }
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

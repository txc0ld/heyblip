import SwiftUI
import CoreBluetooth

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
/// "Blip needs Bluetooth to connect with people nearby."
/// One-tap grant with friendly illustration.
struct PermissionsStep: View {

    /// Called when the user grants permission or skips.
    var onComplete: () -> Void = {}

    @State private var contentVisible = false
    @State private var permissionGranted = false
    @State private var permissionDenied = false
    @State private var observer = BLEPermissionObserver()
    #if DEBUG
    @State private var autoAdvanceTask: Task<Void, Never>?
    #endif
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
                Text("Stay connected\nwithout signal")
                    .font(theme.typography.largeTitle)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Blip needs Bluetooth to connect with people nearby. Your device becomes part of a mesh network that relays messages.")
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
                    Text("Bluetooth enabled")
                        .font(.custom(BlipFontName.medium, size: 15, relativeTo: .body))
                        .foregroundStyle(theme.colors.statusGreen)
                }
                .padding(.bottom, BlipSpacing.md)
            }

            if permissionDenied {
                VStack(spacing: BlipSpacing.sm) {
                    Text("Bluetooth is required for Blip to work.")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.statusAmber)
                        .multilineTextAlignment(.center)

                    Button {
                        openSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.custom(BlipFontName.medium, size: 14, relativeTo: .footnote))
                            .foregroundStyle(Color.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .padding(.horizontal, BlipSpacing.xl)
                .padding(.bottom, BlipSpacing.md)
            }

            Spacer()

            // Action buttons
            VStack(spacing: BlipSpacing.md) {
                GlassButton(
                    permissionGranted ? "Get started" : "Enable Bluetooth",
                    icon: permissionGranted ? "arrow.right" : "antenna.radiowaves.left.and.right"
                ) {
                    if permissionGranted {
                        onComplete()
                    } else {
                        requestBluetoothPermission()
                    }
                }
                .fullWidth()

                if !permissionGranted {
                    Text("Required for Blip to work")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
            .padding(.horizontal, BlipSpacing.lg)
            .padding(.bottom, BlipSpacing.xl)
        }
        .opacity(contentVisible ? 1.0 : 0.0)
        .offset(y: contentVisible ? 0 : 15)
        .onAppear {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                contentVisible = true
            }
            checkCurrentPermission()
            #if DEBUG
            autoAdvanceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                onComplete()
            }
            #endif
        }
        #if DEBUG
        .onDisappear {
            autoAdvanceTask?.cancel()
        }
        #endif
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
                Image(systemName: "bluetooth")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.blipAccentPurple)
            }
        }
    }

    // MARK: - Bluetooth Permission

    private func checkCurrentPermission() {
        handleAuthorization(CBManager.authorization)
    }

    private func requestBluetoothPermission() {
        observer.onStateChange = { authorization in
            handleAuthorization(authorization)
        }
        observer.startRequest()
    }

    private func handleAuthorization(_ authorization: CBManagerAuthorization) {
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

        if authorization == .allowedAlways {
            // Auto-advance after a beat so the user sees the confirmation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                onComplete()
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
        PermissionsStep()
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Permissions Step - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        PermissionsStep()
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

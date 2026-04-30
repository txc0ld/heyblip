import SwiftUI
import AVFoundation
import AudioToolbox

private enum QRScannerL10n {
    static let title = String(localized: "qr_scanner.title", defaultValue: "Scan QR Code")
    static let close = String(localized: "common.close", defaultValue: "Close")
    static let instructions = String(localized: "qr_scanner.instructions", defaultValue: "Point your camera at a HeyBlip QR code")
    static let cameraUnavailable = String(localized: "qr_scanner.camera_unavailable", defaultValue: "Camera Unavailable")
    static let cameraPermission = String(
        localized: "qr_scanner.camera_permission",
        defaultValue: "HeyBlip needs camera access to scan QR codes.\nGo to Settings to enable it."
    )
    static let openSettings = String(localized: "qr_scanner.open_settings", defaultValue: "Open Settings")
    static let scannerAccessibility = String(localized: "qr_scanner.scanner.accessibility", defaultValue: "QR code camera scanner")
}

// MARK: - QR Scanner View

/// Full-screen camera view for scanning HeyBlip QR codes.
/// Parses `heyblip://user/{username}` and legacy `blip://user/{username}` URLs.
struct QRScannerView: View {

    private let onUsernameScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined

    init(onUsernameScanned: @escaping (String) -> Void) {
        self.onUsernameScanned = onUsernameScanned
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                switch cameraPermission {
                case .authorized:
                    cameraPreview
                case .denied, .restricted:
                    permissionDeniedView
                default:
                    requestingPermissionView
                }
            }
            .navigationTitle(QRScannerL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(QRScannerL10n.close) { dismiss() }
                        .foregroundStyle(.blipAccentPurple)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .task {
            await checkCameraPermission()
        }
    }

    // MARK: - Camera Preview

    private var cameraPreview: some View {
        VStack(spacing: BlipSpacing.md) {
            QRCameraRepresentable { scannedString in
                guard let username = parseBlipURL(scannedString) else { return }
                DebugLogger.shared.log("PROFILE", "QR code scanned for user: \(DebugLogger.redact(username))")
                onUsernameScanned(username)
                dismiss()
            }
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .stroke(Color.blipAccentPurple.opacity(0.4), lineWidth: 2)
            )
            .padding(.horizontal, BlipSpacing.md)
            .accessibilityLabel(QRScannerL10n.scannerAccessibility)

            Text(QRScannerL10n.instructions)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, BlipSpacing.lg)
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "camera.fill")
                .font(theme.typography.display)
                .foregroundStyle(theme.colors.mutedText)

            Text(QRScannerL10n.cameraUnavailable)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(QRScannerL10n.cameraPermission)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            Button(action: openAppSettings) {
                Text(QRScannerL10n.openSettings)
                    .font(theme.typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, BlipSpacing.lg)
                    .padding(.vertical, BlipSpacing.sm + 2)
                    .background(Capsule().fill(LinearGradient.blipAccent))
            }
            .frame(minHeight: BlipSizing.minTapTarget)
        }
        .padding(BlipSpacing.xl)
    }

    // MARK: - Requesting Permission

    private var requestingPermissionView: some View {
        // Viewfinder-shaped skeleton — the real camera preview lands inside the
        // same square footprint once the system permission dialog resolves, so
        // the swap is in-place rather than a layout jump.
        VStack(spacing: BlipSpacing.md) {
            ShimmerRect(width: 240, height: 240, cornerRadius: BlipCornerRadius.xl)
        }
    }

    // MARK: - Helpers

    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                cameraPermission = granted ? .authorized : .denied
            }
        } else {
            await MainActor.run {
                cameraPermission = status
            }
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }
}

// MARK: - URL Parsing

/// Parses a HeyBlip user URL and returns the username, or nil if invalid.
func parseBlipUserURL(_ urlString: String) -> String? {
    // Accept both heyblip:// (current) and blip:// (legacy, pre-rename) schemes
    guard let url = URL(string: urlString),
          let scheme = url.scheme,
          ["heyblip", "blip"].contains(scheme),
          url.host == "user" else {
        return nil
    }
    let username = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !username.isEmpty else { return nil }
    return username
}

private func parseBlipURL(_ string: String) -> String? {
    parseBlipUserURL(string)
}

// MARK: - Camera UIViewControllerRepresentable

private struct QRCameraRepresentable: UIViewControllerRepresentable {

    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let controller = QRCameraViewController()
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {}
}

// MARK: - Camera ViewController

private final class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onCodeScanned: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            DebugLogger.shared.log("PROFILE", "QR scanner: no video capture device available", isError: true)
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                DebugLogger.shared.log("PROFILE", "QR scanner: cannot add video input to session", isError: true)
                return
            }
        } catch {
            DebugLogger.shared.log("PROFILE", "QR scanner: failed to create video input: \(error.localizedDescription)", isError: true)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            DebugLogger.shared.log("PROFILE", "QR scanner: cannot add metadata output to session", isError: true)
            return
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview
    }

    private func startSession() {
        guard let session = captureSession, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopSession() {
        guard let session = captureSession, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned else { return }

        guard let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }

        // Only fire for valid HeyBlip user URLs
        guard parseBlipUserURL(stringValue) != nil else { return }

        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onCodeScanned?(stringValue)
    }
}

// MARK: - Preview

#Preview("QR Scanner") {
    QRScannerView { username in
        // Preview callback
        _ = username
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}

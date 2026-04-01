import SwiftUI
import SwiftData
import CryptoKit
import BlipCrypto

// MARK: - OnboardingFlow

/// Three-step onboarding using TabView with .page style.
/// Steps: Welcome, Create Profile, Permissions.
/// All steps are required (no skip) unless bypass code is entered.
struct OnboardingFlow: View {

    /// Called when onboarding is complete.
    var onComplete: () -> Void = {}

    @State private var currentStep: Int = 0
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    /// Total number of onboarding steps.
    private let stepCount = 3

    var body: some View {
        ZStack {
            GradientBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                TabView(selection: $currentStep) {
                    WelcomeStep(
                        onContinue: { advanceToStep(1) },
                        onBypass: { handleBypass() }
                    )
                    .tag(0)

                    CreateProfileStep {
                        advanceToStep(2)
                    }
                    .tag(1)

                    PermissionsStep(
                        onComplete: { completeOnboarding() },
                        isActive: currentStep == 2
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(SpringConstants.accessiblePageEntrance, value: currentStep)

                // Custom page indicator
                pageIndicator
                    .padding(.bottom, BlipSpacing.md)
            }
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: BlipSpacing.sm) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index == currentStep
                            ? Color.blipAccentPurple
                            : (colorScheme == .dark
                                ? Color.white.opacity(0.2)
                                : Color.black.opacity(0.15))
                    )
                    .frame(
                        width: index == currentStep ? 24 : 8,
                        height: 8
                    )
                    .animation(SpringConstants.accessiblePageEntrance, value: currentStep)
            }
        }
    }

    // MARK: - Navigation

    private func advanceToStep(_ step: Int) {
        withAnimation(SpringConstants.accessiblePageEntrance) {
            currentStep = min(step, stepCount - 1)
        }
    }

    private func completeOnboarding() {
        onComplete()
    }

    /// Bypass handler: generates identity, creates local User, registers on backend.
    private func handleBypass() {
        do {
            // Generate cryptographic identity if not already present
            let keyManager = KeyManager.shared
            let identity: Identity
            if let existing = try keyManager.loadIdentity() {
                identity = existing
            } else {
                identity = try keyManager.generateIdentity()
                try keyManager.storeIdentity(identity)
            }

            // Generate a dev username from the device name
            let deviceName = UIDevice.current.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "'", with: "")
                .prefix(16)
            let username = deviceName.isEmpty ? "dev_\(UUID().uuidString.prefix(6))" : String(deviceName)

            // Check if User already exists
            let existingDesc = FetchDescriptor<User>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
            let existingUsers = try modelContext.fetch(existingDesc)

            if existingUsers.isEmpty {
                // Create dev email hash
                let devEmail = "\(username)@dev.blip"
                let emailHash = SHA256.hash(data: Data(devEmail.lowercased().utf8))
                    .compactMap { String(format: "%02x", $0) }
                    .joined()

                let user = User(
                    username: username,
                    displayName: String(deviceName),
                    emailHash: emailHash,
                    noisePublicKey: identity.noisePublicKey.rawRepresentation,
                    signingPublicKey: identity.signingPublicKey,
                    isVerified: true
                )
                modelContext.insert(user)

                try modelContext.save()

                // Register on backend with encryption keys (fire-and-forget)
                let noiseKey = identity.noisePublicKey.rawRepresentation
                let signingKey = identity.signingPublicKey
                Task {
                    try? await UserSyncService().registerUser(
                        emailHash: emailHash,
                        username: username,
                        noisePublicKey: noiseKey,
                        signingPublicKey: signingKey
                    )
                }
            }

            completeOnboarding()
        } catch {
            // Fallback: complete without user creation — profile step can fix later
            completeOnboarding()
        }
    }
}

// MARK: - Preview

#Preview("Onboarding Flow") {
    OnboardingFlow()
        .environment(\.theme, Theme.shared)
}

#Preview("Onboarding Flow - Light") {
    OnboardingFlow()
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}

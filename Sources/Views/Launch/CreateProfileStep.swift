import SwiftUI
import SwiftData
import BlipCrypto

// MARK: - CreateProfileStep

/// Onboarding step 2: Username, email verification, optional avatar picker, identity generation.
/// Single glass card layout.
struct CreateProfileStep: View {

    /// Called when the user completes profile creation.
    var onComplete: () -> Void = {}

    @State private var username: String = ""
    @State private var email: String = ""
    @State private var otpCode: String = ""
    @State private var showOTPField = false
    @State private var isSendingCode = false
    @State private var isVerifyingCode = false
    @State private var isEmailVerified = false
    @State private var isCreatingIdentity = false
    @State private var showAvatarPicker = false
    @State private var selectedAvatarImage: UIImage? = nil
    @State private var usernameError: String? = nil
    @State private var emailError: String? = nil
    @State private var identityError: String? = nil
    @State private var contentVisible = false
    @State private var resendCooldown: Int = 0
    @State private var resendCooldownTimer: Timer?
    @FocusState private var focusedField: Field?
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    private let verificationService = EmailVerificationService()

    private enum Field: Hashable {
        case username
        case email
        case otp
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BlipSpacing.lg) {
                // Title
                VStack(spacing: BlipSpacing.sm) {
                    Text("Create your profile")
                        .font(theme.typography.largeTitle)
                        .foregroundStyle(theme.colors.text)

                    Text("Pick a username and verify your email.")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, BlipSpacing.xl)

                // Avatar picker
                avatarSection

                // Form card
                GlassCard(thickness: .regular) {
                    VStack(spacing: BlipSpacing.md) {
                        usernameField

                        Divider()
                            .overlay(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))

                        emailField

                        if showOTPField {
                            Divider()
                                .overlay(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                            otpField
                        }
                    }
                }
                .padding(.horizontal, BlipSpacing.md)

                // Error alerts
                if let error = emailError ?? identityError {
                    Text(error)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, BlipSpacing.lg)
                        .transition(.opacity)
                }

                // Continue button
                GlassButton(
                    "Continue",
                    icon: isEmailVerified ? "checkmark" : "arrow.right",
                    isLoading: isCreatingIdentity
                ) {
                    Task { await createProfile() }
                }
                .fullWidth()
                .disabled(!isFormValid || isCreatingIdentity)
                .padding(.horizontal, BlipSpacing.lg)
                .padding(.bottom, BlipSpacing.xl)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .opacity(contentVisible ? 1.0 : 0.0)
        .offset(y: contentVisible ? 0 : 15)
        .onAppear {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                contentVisible = true
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        Button {
            showAvatarPicker = true
        } label: {
            ZStack {
                if let image = selectedAvatarImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                        .overlay(
                            Circle()
                                .stroke(
                                    colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1),
                                    lineWidth: BlipSizing.hairline
                                )
                        )
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(theme.colors.mutedText)
                        )
                }

                Circle()
                    .fill(Color.blipAccentPurple)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 28, y: 28)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("Choose profile photo")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Username Field

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text("Username")
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)

            TextField("", text: $username)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .username)
                .frame(minHeight: BlipSizing.minTapTarget)
                .overlay(alignment: .leading) {
                    if username.isEmpty {
                        Text("Choose a username")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.mutedText.opacity(0.6))
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: username) { _, newValue in
                    validateUsername(newValue)
                }

            if let error = usernameError {
                Text(error)
                    .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.statusRed)
            }
        }
    }

    // MARK: - Email Field

    private var emailField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text("Email")
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)

            HStack {
                TextField("", text: $email)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .overlay(alignment: .leading) {
                        if email.isEmpty {
                            Text("you@example.com")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.mutedText.opacity(0.6))
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isEmailVerified)

                if !showOTPField && !email.isEmpty && !isEmailVerified {
                    Button {
                        Task { await sendVerificationCode() }
                    } label: {
                        if isSendingCode {
                            ProgressView()
                                .tint(Color.blipAccentPurple)
                        } else {
                            Text("Verify")
                                .font(.custom(BlipFontName.semiBold, size: 14, relativeTo: .footnote))
                                .foregroundStyle(Color.blipAccentPurple)
                        }
                    }
                    .disabled(isSendingCode)
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                }

                if isEmailVerified {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.colors.statusGreen)
                }
            }
        }
    }

    // MARK: - OTP Field

    private var otpField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text("Verification code")
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)

            HStack {
                TextField("", text: $otpCode)
                    .font(.custom(BlipFontName.semiBold, size: 20, relativeTo: .title3))
                    .foregroundStyle(theme.colors.text)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .otp)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .overlay(alignment: .leading) {
                        if otpCode.isEmpty {
                            Text("000000")
                                .font(.custom(BlipFontName.semiBold, size: 20, relativeTo: .title3))
                                .foregroundStyle(theme.colors.mutedText.opacity(0.4))
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: otpCode) { _, code in
                        if code.count == 6 {
                            Task { await verifyOTP(code) }
                        }
                    }

                if isVerifyingCode {
                    ProgressView()
                        .tint(theme.colors.mutedText)
                }
            }

            Button {
                Task { await sendVerificationCode() }
            } label: {
                if resendCooldown > 0 {
                    Text("Resend in \(resendCooldown)s")
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                } else {
                    Text("Resend code")
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(Color.blipAccentPurple)
                }
            }
            .disabled(isSendingCode || resendCooldown > 0)
            .frame(minHeight: BlipSizing.minTapTarget)
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        !username.isEmpty
        && username.count >= 3
        && usernameError == nil
        && isEmailVerified
    }

    private func validateUsername(_ value: String) {
        if value.isEmpty {
            usernameError = nil
            return
        }
        if value.count < 3 {
            usernameError = "Username must be at least 3 characters"
            return
        }
        if value.count > 32 {
            usernameError = "Username must be 32 characters or fewer"
            return
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            usernameError = "Only letters, numbers, hyphens, dots, underscores"
            return
        }
        usernameError = nil
    }

    // MARK: - Email Verification

    private func sendVerificationCode() async {
        isSendingCode = true
        emailError = nil

        do {
            try await verificationService.sendCode(to: email)
            withAnimation(SpringConstants.accessiblePageEntrance) {
                showOTPField = true
            }
            focusedField = .otp
            startResendCooldown()
        } catch {
            emailError = error.localizedDescription
        }

        isSendingCode = false
    }

    private func startResendCooldown() {
        resendCooldown = 60
        resendCooldownTimer?.invalidate()
        resendCooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if resendCooldown > 0 {
                    resendCooldown -= 1
                } else {
                    resendCooldownTimer?.invalidate()
                    resendCooldownTimer = nil
                }
            }
        }
    }

    private func verifyOTP(_ code: String) async {
        isVerifyingCode = true
        emailError = nil

        do {
            try await verificationService.verifyCode(email: email, code: code)
            withAnimation(SpringConstants.accessiblePageEntrance) {
                isEmailVerified = true
                showOTPField = false
            }
        } catch let error as EmailVerificationService.EmailVerificationError {
            switch error {
            case .incorrectCode:
                emailError = error.localizedDescription
            case .codeExpired, .tooManyAttempts:
                emailError = error.localizedDescription
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    showOTPField = false
                    otpCode = ""
                }
            default:
                emailError = error.localizedDescription
            }
        } catch {
            emailError = error.localizedDescription
        }

        isVerifyingCode = false
    }

    // MARK: - Identity Generation

    private func createProfile() async {
        isCreatingIdentity = true
        identityError = nil
        usernameError = nil

        do {
            // Reuse identity from a previous attempt, or generate a new one
            let identity: Identity
            if let existing = try KeyManager.shared.loadIdentity() {
                identity = existing
            } else {
                identity = try KeyManager.shared.generateIdentity()
                try KeyManager.shared.storeIdentity(identity)
            }

            let thumbnailData = selectedAvatarImage?
                .jpegData(compressionQuality: 0.5)

            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

            let emailHash = email
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .data(using: .utf8)
                .map { data in
                    SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                } ?? ""

            // Save locally first (idempotent — updates existing record on retry)
            let existingUsers = try modelContext.fetch(FetchDescriptor<User>())
            let user: User
            if let existing = existingUsers.first {
                existing.username = trimmedUsername
                existing.displayName = trimmedUsername
                user = existing
            } else {
                user = User(
                    username: trimmedUsername,
                    displayName: trimmedUsername,
                    emailHash: emailHash,
                    noisePublicKey: identity.noisePublicKey.rawRepresentation,
                    signingPublicKey: identity.signingPublicKey,
                    avatarThumbnail: thumbnailData
                )
                modelContext.insert(user)
            }

            if try modelContext.fetch(FetchDescriptor<UserPreferences>()).isEmpty {
                let preferences = UserPreferences()
                preferences.theme = appTheme
                preferences.defaultLocationSharing = .fuzzy
                modelContext.insert(preferences)
            }

            try modelContext.save()

            // Register on backend — await so we can surface errors
            let noiseKey = identity.noisePublicKey.rawRepresentation
            let signingKey = identity.signingPublicKey
            do {
                try await UserSyncService().registerUser(
                    emailHash: emailHash,
                    username: trimmedUsername,
                    noisePublicKey: noiseKey,
                    signingPublicKey: signingKey
                )
            } catch UserSyncService.SyncError.usernameTaken {
                // Username conflict — roll back local data so user can pick a new name
                modelContext.delete(user)
                for pref in (try? modelContext.fetch(FetchDescriptor<UserPreferences>())) ?? [] {
                    modelContext.delete(pref)
                }
                try? modelContext.save()
                try? KeyManager.shared.deleteIdentity()
                usernameError = "Username already taken. Try a different one."
                DebugLogger.shared.log("AUTH", "Username '\(trimmedUsername)' already taken", isError: true)
                isCreatingIdentity = false
                return
            } catch let error as UserSyncService.SyncError {
                // Non-fatal — log, queue background retry, still proceed
                DebugLogger.shared.log("AUTH", "Registration failed (will retry): \(error.localizedDescription)", isError: true)
                let svc = UserSyncService()
                Task {
                    await svc.registerUserWithRetry(
                        emailHash: emailHash,
                        username: trimmedUsername,
                        noisePublicKey: noiseKey,
                        signingPublicKey: signingKey
                    )
                }
            } catch {
                DebugLogger.shared.log("AUTH", "Registration failed (will retry): \(error.localizedDescription)", isError: true)
                let svc = UserSyncService()
                Task {
                    await svc.registerUserWithRetry(
                        emailHash: emailHash,
                        username: trimmedUsername,
                        noisePublicKey: noiseKey,
                        signingPublicKey: signingKey
                    )
                }
            }

            onComplete()
        } catch {
            identityError = "Failed to create identity: \(error.localizedDescription)"
        }

        isCreatingIdentity = false
    }
}

// MARK: - SHA256 import

import CryptoKit

// MARK: - Preview

#Preview("Create Profile Step") {
    ZStack {
        GradientBackground()
            .ignoresSafeArea()
        CreateProfileStep()
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Create Profile Step - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        CreateProfileStep()
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

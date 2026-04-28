import SwiftUI
import SwiftData
import BlipCrypto
import PhotosUI

private enum CreateProfileL10n {
    static let title = String(localized: "onboarding.profile.title", defaultValue: "Create your profile")
    static let subtitle = String(localized: "onboarding.profile.subtitle", defaultValue: "Pick a username and verify your email.")
    static let continueButton = String(localized: "common.continue", defaultValue: "Continue")
    static let continueHint = String(localized: "onboarding.profile.continue_hint", defaultValue: "Creates your profile and continues to permissions.")
    static let choosePhotoLabel = String(localized: "onboarding.profile.avatar.label", defaultValue: "Choose profile photo")
    static let choosePhotoHint = String(localized: "onboarding.profile.avatar.hint", defaultValue: "Double tap to open your photo library.")
    static let usernameLabel = String(localized: "onboarding.profile.username.label", defaultValue: "Username")
    static let usernameHint = String(localized: "onboarding.profile.username.hint", defaultValue: "Enter your desired username, 3 to 32 characters.")
    static let usernamePlaceholder = String(localized: "onboarding.profile.username.placeholder", defaultValue: "Choose a username")
    static let emailLabel = String(localized: "onboarding.profile.email.label", defaultValue: "Email")
    static let emailAccessibilityLabel = String(localized: "onboarding.profile.email.accessibility_label", defaultValue: "Email address")
    static let emailHint = String(localized: "onboarding.profile.email.hint", defaultValue: "Enter your email address to receive a verification code.")
    static let emailPlaceholder = String(localized: "onboarding.profile.email.placeholder", defaultValue: "you@example.com")
    static let sendingEmailLabel = String(localized: "onboarding.profile.email.sending", defaultValue: "Sending verification email")
    static let verifyButton = String(localized: "onboarding.profile.email.verify", defaultValue: "Verify")
    static let verifyAccessibilityLabel = String(localized: "onboarding.profile.email.verify_accessibility_label", defaultValue: "Verify email")
    static let verifyAccessibilityHint = String(localized: "onboarding.profile.email.verify_accessibility_hint", defaultValue: "Send a verification code to your email address.")
    static let otpLabel = String(localized: "onboarding.profile.otp.label", defaultValue: "Verification code")
    static let otpHint = String(localized: "onboarding.profile.otp.hint", defaultValue: "Enter the 6-digit code sent to your email address.")
    static let otpPlaceholder = String(localized: "onboarding.profile.otp.placeholder", defaultValue: "000000")
    static let verifyingCodeLabel = String(localized: "onboarding.profile.otp.verifying", defaultValue: "Verifying code")
    static let resendButton = String(localized: "onboarding.profile.otp.resend", defaultValue: "Resend code")
    static let resendAccessibilityLabel = String(localized: "onboarding.profile.otp.resend_accessibility_label", defaultValue: "Resend verification code")
    static let resendAccessibilityHint = String(localized: "onboarding.profile.otp.resend_accessibility_hint", defaultValue: "Send a new verification code to your email address.")
    static let usernameTooShort = String(localized: "onboarding.profile.username.error.too_short", defaultValue: "Username must be at least 3 characters")
    static let usernameTooLong = String(localized: "onboarding.profile.username.error.too_long", defaultValue: "Username must be 32 characters or fewer")
    static let usernameInvalidCharacters = String(localized: "onboarding.profile.username.error.invalid_characters", defaultValue: "Only letters, numbers, hyphens, dots, underscores")
    static let usernameTaken = String(localized: "onboarding.profile.username.error.taken", defaultValue: "Username already taken. Try a different one.")
    static let identityErrorFormat = String(localized: "onboarding.profile.identity.error_format", defaultValue: "Failed to create identity: %@")

    static func resendCountdown(_ seconds: Int) -> String {
        String(format: String(localized: "onboarding.profile.otp.resend_countdown", defaultValue: "Resend in %ds"), locale: Locale.current, seconds)
    }

    static func identityError(_ error: String) -> String {
        String(format: identityErrorFormat, locale: Locale.current, error)
    }
}

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
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedAvatarImage: UIImage? = nil
    @State private var usernameError: String? = nil
    @State private var emailError: String? = nil
    @State private var identityError: String? = nil
    @State private var contentVisible = false
    @State private var resendCooldown: Int = 0
    @State private var cooldownTask: Task<Void, Never>?
    @State private var showRegistrationError = false
    @State private var registrationErrorMessage: String?
    @State private var pendingRegistrationRetry: (() async -> Void)?
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
                    Text(CreateProfileL10n.title)
                        .font(theme.typography.largeTitle)
                        .foregroundStyle(theme.colors.text)

                    Text(CreateProfileL10n.subtitle)
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
                    CreateProfileL10n.continueButton,
                    icon: isEmailVerified ? "checkmark" : "arrow.right",
                    isLoading: isCreatingIdentity
                ) {
                    Task { await createProfile() }
                }
                .fullWidth()
                .disabled(!isFormValid || isCreatingIdentity)
                .accessibilityHint(CreateProfileL10n.continueHint)
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
        .onDisappear {
            cooldownTask?.cancel()
        }
        .alert(
            String(localized: "onboarding.profile.registration_error.title", defaultValue: "Registration Failed"),
            isPresented: $showRegistrationError
        ) {
            Button(String(localized: "onboarding.profile.registration_error.retry", defaultValue: "Retry")) {
                guard let retry = pendingRegistrationRetry else { return }
                isCreatingIdentity = true
                Task {
                    await retry()
                    isCreatingIdentity = false
                }
            }
            Button(String(localized: "onboarding.profile.registration_error.continue_offline", defaultValue: "Continue Offline"), role: .cancel) {
                onComplete()
            }
        } message: {
            Text(registrationErrorMessage ?? String(localized: "onboarding.profile.registration_error.message", defaultValue: "Your profile was saved locally but could not be registered on the server. You can retry now or continue — the app will keep trying in the background."))
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
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
                                .font(theme.typography.title2)
                                .foregroundStyle(theme.colors.mutedText)
                        )
                }

                Circle()
                    .fill(Color.blipAccentPurple)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "plus")
                            .font(theme.typography.caption)
                            .foregroundStyle(.white)
                    )
                    .offset(x: 28, y: 28)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CreateProfileL10n.choosePhotoLabel)
        .accessibilityHint(CreateProfileL10n.choosePhotoHint)
        .accessibilityAddTraits(.isButton)
        .onChange(of: selectedAvatarItem) { _, newItem in
            Task {
                do {
                    if let data = try await newItem?.loadTransferable(type: Data.self),
                       let uiImage = ImageDownsampling.downsampledImage(from: data) {
                        selectedAvatarImage = uiImage
                    }
                } catch {
                    DebugLogger.shared.log("AUTH", "Failed to load avatar image: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    // MARK: - Username Field

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(CreateProfileL10n.usernameLabel)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)
                .accessibilityHidden(true)

            TextField("", text: $username, prompt: Text(CreateProfileL10n.usernamePlaceholder)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText.opacity(0.6)))
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .username)
                .frame(minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(CreateProfileL10n.usernameLabel)
                .accessibilityHint(CreateProfileL10n.usernameHint)
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
            Text(CreateProfileL10n.emailLabel)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)
                .accessibilityHidden(true)

            HStack {
                TextField("", text: $email, prompt: Text(CreateProfileL10n.emailPlaceholder)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.6)))
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(CreateProfileL10n.emailAccessibilityLabel)
                    .accessibilityHint(CreateProfileL10n.emailHint)
                    .disabled(isEmailVerified)

                if !showOTPField && !email.isEmpty && !isEmailVerified {
                    Button {
                        Task { await sendVerificationCode() }
                    } label: {
                        if isSendingCode {
                            Skeleton(.inlineBusy(tint: Color.blipAccentPurple))
                                .accessibilityLabel(CreateProfileL10n.sendingEmailLabel)
                        } else {
                            Text(CreateProfileL10n.verifyButton)
                                .font(.custom(BlipFontName.semiBold, size: 14, relativeTo: .footnote))
                                .foregroundStyle(Color.blipAccentPurple)
                        }
                    }
                    .disabled(isSendingCode)
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(CreateProfileL10n.verifyAccessibilityLabel)
                    .accessibilityHint(CreateProfileL10n.verifyAccessibilityHint)
                }

                if isEmailVerified {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.colors.statusGreen)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - OTP Field

    private var otpField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(CreateProfileL10n.otpLabel)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)
                .accessibilityHidden(true)

            HStack {
                TextField("", text: $otpCode, prompt: Text(CreateProfileL10n.otpPlaceholder)
                    .font(.custom(BlipFontName.semiBold, size: 20, relativeTo: .title3))
                    .foregroundStyle(theme.colors.mutedText.opacity(0.4)))
                    .font(.custom(BlipFontName.semiBold, size: 20, relativeTo: .title3))
                    .foregroundStyle(theme.colors.text)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .otp)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(CreateProfileL10n.otpLabel)
                    .accessibilityHint(CreateProfileL10n.otpHint)
                    .onChange(of: otpCode) { _, code in
                        if code.count == 6 {
                            Task { await verifyOTP(code) }
                        }
                    }

                if isVerifyingCode {
                    Skeleton(.inlineBusy(tint: theme.colors.mutedText))
                        .accessibilityLabel(CreateProfileL10n.verifyingCodeLabel)
                }
            }

            Button {
                Task { await sendVerificationCode() }
            } label: {
                if resendCooldown > 0 {
                    Text(CreateProfileL10n.resendCountdown(resendCooldown))
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                } else {
                    Text(CreateProfileL10n.resendButton)
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(Color.blipAccentPurple)
                }
            }
            .disabled(isSendingCode || resendCooldown > 0)
            .frame(minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(CreateProfileL10n.resendAccessibilityLabel)
            .accessibilityHint(CreateProfileL10n.resendAccessibilityHint)
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
            usernameError = CreateProfileL10n.usernameTooShort
            return
        }
        if value.count > 32 {
            usernameError = CreateProfileL10n.usernameTooLong
            return
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            usernameError = CreateProfileL10n.usernameInvalidCharacters
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
        cooldownTask?.cancel()
        resendCooldown = 60
        cooldownTask = Task { @MainActor in
            while resendCooldown > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                resendCooldown -= 1
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
                usernameError = CreateProfileL10n.usernameTaken
                DebugLogger.shared.log("AUTH", "Username '\(trimmedUsername)' already taken", isError: true)
                isCreatingIdentity = false
                return
            } catch {
                DebugLogger.shared.log("AUTH", "Registration failed: \(error.localizedDescription)", isError: true)
                registrationErrorMessage = error.localizedDescription
                pendingRegistrationRetry = { [noiseKey, signingKey] in
                    do {
                        try await UserSyncService().registerUser(
                            emailHash: emailHash,
                            username: trimmedUsername,
                            noisePublicKey: noiseKey,
                            signingPublicKey: signingKey
                        )
                        await MainActor.run { self.onComplete() }
                    } catch {
                        DebugLogger.shared.log("AUTH", "Registration retry failed: \(error.localizedDescription)", isError: true)
                        await MainActor.run {
                            self.registrationErrorMessage = error.localizedDescription
                            self.showRegistrationError = true
                        }
                    }
                }
                isCreatingIdentity = false
                showRegistrationError = true
                return
            }

            onComplete()
        } catch {
            identityError = CreateProfileL10n.identityError(error.localizedDescription)
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

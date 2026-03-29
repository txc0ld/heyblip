import SwiftUI
import SwiftData
import FestiChatCrypto

// MARK: - CreateProfileStep

/// Onboarding step 2: Username, optional avatar picker, identity generation.
/// Single glass card layout.
struct CreateProfileStep: View {

    /// Called when the user completes profile creation.
    var onComplete: () -> Void = {}

    @State private var username: String = ""
    @State private var isCreatingIdentity = false
    @State private var showAvatarPicker = false
    @State private var selectedAvatarImage: UIImage? = nil
    @State private var usernameError: String? = nil
    @State private var identityError: String? = nil
    @State private var contentVisible = false
    @FocusState private var focusedField: Field?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    private enum Field: Hashable {
        case username
    }

    var body: some View {
        ScrollView {
            VStack(spacing: FCSpacing.lg) {
                // Title
                VStack(spacing: FCSpacing.sm) {
                    Text("Create your profile")
                        .font(theme.typography.largeTitle)
                        .foregroundStyle(theme.colors.text)

                    Text("Pick a username and optionally add a photo.")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, FCSpacing.xl)

                // Avatar picker
                avatarSection

                // Form card
                GlassCard(thickness: .regular) {
                    VStack(spacing: FCSpacing.md) {
                        // Username field
                        usernameField
                    }
                }
                .padding(.horizontal, FCSpacing.md)

                // Identity error alert
                if let error = identityError {
                    Text(error)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, FCSpacing.lg)
                }

                // Continue button
                GlassButton(
                    "Continue",
                    icon: "arrow.right",
                    isLoading: isCreatingIdentity
                ) {
                    Task { await createProfile() }
                }
                .fullWidth()
                .disabled(!isFormValid || isCreatingIdentity)
                .padding(.horizontal, FCSpacing.lg)
                .padding(.bottom, FCSpacing.xl)
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
                        .frame(width: FCSizing.avatarLarge, height: FCSizing.avatarLarge)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: FCSizing.avatarLarge, height: FCSizing.avatarLarge)
                        .overlay(
                            Circle()
                                .stroke(
                                    colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1),
                                    lineWidth: FCSizing.hairline
                                )
                        )
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(theme.colors.mutedText)
                        )
                }

                // Edit badge
                Circle()
                    .fill(Color.fcAccentPurple)
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
        .frame(minWidth: FCSizing.minTapTarget, minHeight: FCSizing.minTapTarget)
        .accessibilityLabel("Choose profile photo")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Username Field

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: FCSpacing.xs) {
            Text("Username")
                .font(.custom(FCFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(theme.colors.mutedText)

            TextField("", text: $username)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .username)
                .frame(minHeight: FCSizing.minTapTarget)
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
                    .font(.custom(FCFontName.regular, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.statusRed)
            }
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        !username.isEmpty
        && username.count >= 3
        && usernameError == nil
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

    // MARK: - Identity Generation

    private func createProfile() async {
        isCreatingIdentity = true
        identityError = nil

        do {
            let identity = try KeyManager.shared.generateIdentity()
            try KeyManager.shared.storeIdentity(identity)

            // Compress avatar for thumbnail if selected.
            let thumbnailData = selectedAvatarImage?
                .jpegData(compressionQuality: 0.5)

            let user = User(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: username,
                phoneHash: "",
                noisePublicKey: identity.noisePublicKey.rawRepresentation,
                signingPublicKey: identity.signingPublicKey,
                avatarThumbnail: thumbnailData
            )

            modelContext.insert(user)
            try modelContext.save()

            onComplete()
        } catch {
            identityError = "Failed to create identity: \(error.localizedDescription)"
        }

        isCreatingIdentity = false
    }
}

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

import SwiftUI
import SwiftData
import PhotosUI
import os.log

private enum EditProfileL10n {
    static let title = String(localized: "profile.edit.title", defaultValue: "Edit Profile")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let save = String(localized: "common.save", defaultValue: "Save")
    static let choosePhoto = String(localized: "profile.edit.avatar.choose_photo", defaultValue: "Choose Photo")
    static let takePhoto = String(localized: "profile.edit.avatar.take_photo", defaultValue: "Take Photo")
    static let displayName = String(localized: "profile.edit.display_name.label", defaultValue: "Display Name")
    static let displayNamePlaceholder = String(localized: "profile.edit.display_name.placeholder", defaultValue: "Your name")
    static let displayNameAccessibility = String(localized: "profile.edit.display_name.accessibility_label", defaultValue: "Display name")
    static let username = String(localized: "profile.edit.username.label", defaultValue: "Username")
    static let usernamePlaceholder = String(localized: "profile.edit.username.placeholder", defaultValue: "username")
    static let usernameAccessibility = String(localized: "profile.edit.username.accessibility_label", defaultValue: "Username")
    static let bio = String(localized: "profile.edit.bio.label", defaultValue: "Bio")
    static let email = String(localized: "profile.edit.email.label", defaultValue: "Email")
    static let changeEmail = String(localized: "profile.edit.email.change", defaultValue: "Change Email")
    static let changeEmailAccessibility = String(localized: "profile.edit.email.change_accessibility_label", defaultValue: "Change email address — unavailable")
    static let verifiedEmail = String(localized: "profile.edit.email.verified_placeholder", defaultValue: "Verified email")
    static let usernameCharacters = String(localized: "profile.edit.username.error.characters", defaultValue: "Letters, numbers, and underscores only")
    static let usernameTooShort = String(localized: "profile.edit.username.error.too_short", defaultValue: "At least 3 characters")

    static func bioAccessibility(_ count: Int, _ max: Int) -> String {
        String(format: String(localized: "profile.edit.bio.accessibility_label", defaultValue: "Bio, %d of %d characters"), locale: Locale.current, count, max)
    }

    static let choosePhotoHint = String(localized: "profile.edit.avatar.choose_photo_hint", defaultValue: "Opens your photo library to select a profile picture")
    static let takePhotoHint = String(localized: "profile.edit.avatar.take_photo_hint", defaultValue: "Opens the camera to take a profile picture")

    static func usernameMax(_ max: Int) -> String {
        String(format: String(localized: "profile.edit.username.error.maximum", defaultValue: "Maximum %d characters"), locale: Locale.current, max)
    }
}

// MARK: - EditProfileView

/// Edit screen for display name, username, bio, avatar, and email.
/// Persists changes to SwiftData.
@MainActor
struct EditProfileView: View {

    @Binding var isPresented: Bool

    @Query private var users: [User]
    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarImage: Image?
    @State private var avatarData: Data?
    @State private var showCameraPicker = false
    @State private var showAvatarCrop = false
    @State private var cropSourceImage: UIImage?
    @State private var showEmailVerify = false
    @State private var usernameError: String?
    @State private var isSaving = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @FocusState private var focusedField: EditField?

    private let maxBioLength = 140
    private let maxUsernameLength = 32

    private var user: User? { users.first }

    init(isPresented: Binding<Bool>, displayName: String, username: String, bio: String) {
        self._isPresented = isPresented
        self._displayName = State(initialValue: displayName)
        self._username = State(initialValue: username)
        self._bio = State(initialValue: bio)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(spacing: BlipSpacing.lg) {
                        avatarSection
                        nameSection
                        usernameSection
                        bioSection
                        emailSection
                    }
                    .padding(BlipSpacing.md)
                }
            }
            .navigationTitle(EditProfileL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(EditProfileL10n.cancel) { isPresented = false }
                        .foregroundStyle(theme.colors.mutedText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(EditProfileL10n.save) { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.blipAccentPurple)
                        .disabled(isSaving || !isValid)
                }
            }
            .sheet(isPresented: $showAvatarCrop) {
                if let sourceImage = cropSourceImage {
                    AvatarCropView(isPresented: $showAvatarCrop, image: sourceImage) { cropRect in
                        let renderer = UIGraphicsImageRenderer(size: CGSize(
                            width: sourceImage.size.width * cropRect.width,
                            height: sourceImage.size.height * cropRect.height
                        ))
                        let cropped = renderer.image { _ in
                            sourceImage.draw(at: CGPoint(
                                x: -sourceImage.size.width * cropRect.origin.x,
                                y: -sourceImage.size.height * cropRect.origin.y
                            ))
                        }
                        avatarImage = Image(uiImage: cropped)
                        avatarData = cropped.jpegData(compressionQuality: 0.8)
                    }
                    .presentationDetents([.large])
                }
            }
            .fullScreenCover(isPresented: $showCameraPicker) {
                SystemImagePicker(isPresented: $showCameraPicker, sourceType: .camera) { image in
                    cropSourceImage = image
                    avatarImage = Image(uiImage: image)
                    avatarData = image.jpegData(compressionQuality: 0.8)
                    showAvatarCrop = true
                }
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        let secondaryFont = theme.typography.secondary

        return GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                ZStack {
                    if let avatarImage {
                        avatarImage
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(LinearGradient.blipAccent)
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(theme.typography.title2)
                                    .foregroundStyle(.white.opacity(0.8))
                            )
                    }
                }

                HStack(spacing: BlipSpacing.md) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(EditProfileL10n.choosePhoto, systemImage: "photo.on.rectangle")
                            .font(secondaryFont)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityHint(EditProfileL10n.choosePhotoHint)

                    Button(action: { showCameraPicker = true }) {
                        Label(EditProfileL10n.takePhoto, systemImage: "camera")
                            .font(secondaryFont)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityHint(EditProfileL10n.takePhotoHint)
                    .disabled(!SystemImagePicker.isAvailable(.camera))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: selectedPhoto) { _, newItem in
            Task {
                do {
                    if let data = try await newItem?.loadTransferable(type: Data.self),
                       let uiImage = ImageDownsampling.downsampledImage(from: data) {
                        // JPEG re-encode runs off main to avoid a brief UI hitch
                        // on slower devices when the source image is near 2048 px.
                        let jpegData = await Task.detached(priority: .userInitiated) {
                            uiImage.jpegData(compressionQuality: 0.8)
                        }.value
                        avatarImage = Image(uiImage: uiImage)
                        avatarData = jpegData
                        cropSourceImage = uiImage
                        showAvatarCrop = true
                    }
                } catch {
                    DebugLogger.shared.log("PROFILE", "Failed to load photo: \(error.localizedDescription)", isError: true)
                }
            }
        }
        .onAppear {
            if avatarImage == nil, let data = user?.avatarThumbnail, let uiImage = UIImage(data: data) {
                avatarImage = Image(uiImage: uiImage)
                cropSourceImage = uiImage
            }
        }
    }

    // MARK: - Name Section

    private var nameSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(EditProfileL10n.displayName)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                TextField(EditProfileL10n.displayNamePlaceholder, text: $displayName)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .focused($focusedField, equals: .name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                    .padding(BlipSpacing.md)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
                    .accessibilityLabel(EditProfileL10n.displayNameAccessibility)
            }
        }
    }

    // MARK: - Username Section

    private var usernameSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(EditProfileL10n.username)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                HStack(spacing: 0) {
                    Text("@")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.leading, BlipSpacing.md)

                    TextField(EditProfileL10n.usernamePlaceholder, text: $username)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)
                        .focused($focusedField, equals: .username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focusedField = .bio }
                        .onChange(of: username) { _, newValue in
                            validateUsername(newValue)
                        }
                        .padding(.vertical, BlipSpacing.md)
                        .padding(.trailing, BlipSpacing.md)
                }
                .background(fieldBackground)
                .overlay(fieldBorder)
                .accessibilityLabel(EditProfileL10n.usernameAccessibility)

                if let error = usernameError {
                    Text(error)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                }

                Text("\(username.count)/\(maxUsernameLength)")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Bio Section

    private var bioSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(EditProfileL10n.bio)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                TextEditor(text: $bio)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .focused($focusedField, equals: .bio)
                    .frame(minHeight: 80)
                    .padding(BlipSpacing.sm)
                    .scrollContentBackground(.hidden)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
                    .accessibilityLabel(EditProfileL10n.bioAccessibility(bio.count, maxBioLength))
                    .onChange(of: bio) { _, newValue in
                        if newValue.count > maxBioLength {
                            bio = String(newValue.prefix(maxBioLength))
                        }
                    }

                Text("\(bio.count)/\(maxBioLength)")
                    .font(theme.typography.caption)
                    .foregroundStyle(bio.count >= maxBioLength ? theme.colors.statusAmber : theme.colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Email Section

    private var emailSection: some View {
        GlassCard(thickness: .regular) {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(EditProfileL10n.email)
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    HStack(spacing: BlipSpacing.xs) {
                        Text(maskedEmail)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.mutedText)

                        Image(systemName: "checkmark.circle.fill")
                            .font(theme.typography.caption)
                            .foregroundStyle(BlipColors.adaptive.statusGreen)
                    }
                }

                Spacer()

                // TODO: BDEV-136 — implement email change flow with server verification
                Button(action: { showEmailVerify = true }) {
                    Text(EditProfileL10n.changeEmail)
                        .font(theme.typography.caption)
                        .foregroundStyle(.blipAccentPurple)
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(
                            Capsule()
                                .fill(.blipAccentPurple.opacity(0.12))
                        )
                }
                .frame(minHeight: BlipSizing.minTapTarget)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel(EditProfileL10n.changeEmailAccessibility)
            }
        }
    }

    /// Masked email display (e.g., "t***@gmail.com").
    private var maskedEmail: String {
        // Email hash is stored, not raw email — show masked placeholder.
        // In production, the raw email could be stored locally for display.
        EditProfileL10n.verifiedEmail
    }

    // MARK: - Shared Components

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
            .fill(.ultraThinMaterial)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
            .stroke(
                colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08),
                lineWidth: BlipSizing.hairline
            )
    }

    // MARK: - Validation

    private func validateUsername(_ value: String) {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if value.unicodeScalars.contains(where: { !allowedCharacters.contains($0) }) {
            usernameError = EditProfileL10n.usernameCharacters
        } else if value.count < 3 {
            usernameError = EditProfileL10n.usernameTooShort
        } else if value.count > maxUsernameLength {
            usernameError = EditProfileL10n.usernameMax(maxUsernameLength)
            username = String(value.prefix(maxUsernameLength))
        } else {
            usernameError = nil
        }
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        && username.count >= 3
        && username.count <= maxUsernameLength
        && usernameError == nil
    }

    private func save() {
        isSaving = true

        guard let user else {
            isSaving = false
            return
        }

        user.displayName = displayName.trimmingCharacters(in: .whitespaces)
        user.username = username.trimmingCharacters(in: .whitespaces)
        user.bio = bio.trimmingCharacters(in: .whitespaces)

        if let avatarData {
            user.avatarThumbnail = avatarData
        }

        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "com.blip", category: "EditProfile")
                .error("Failed to save profile: \(error.localizedDescription)")
        }

        isSaving = false
        isPresented = false
    }

    private enum EditField {
        case name, username, bio
    }
}

// MARK: - Preview

#Preview("Edit Profile") {
    EditProfileView(
        isPresented: .constant(true),
        displayName: "Alex Rivers",
        username: "alexrivers",
        bio: "Event lover."
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

import SwiftUI
import SwiftData
import PhotosUI
import os.log

// MARK: - EditProfileView

/// Edit screen for display name, username, bio, avatar, and email.
/// Persists changes to SwiftData.
struct EditProfileView: View {

    @Binding var isPresented: Bool

    @Query private var users: [User]
    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarImage: Image?
    @State private var avatarData: Data?
    @State private var showAvatarCrop = false
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
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundStyle(theme.colors.mutedText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.blipAccentPurple)
                        .disabled(isSaving || !isValid)
                }
            }
            .sheet(isPresented: $showAvatarCrop) {
                AvatarCropView(isPresented: $showAvatarCrop)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        GlassCard(thickness: .regular) {
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
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.8))
                            )
                    }
                }

                HStack(spacing: BlipSpacing.md) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .font(theme.typography.secondary)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)

                    Button(action: { showAvatarCrop = true }) {
                        Label("Take Photo", systemImage: "camera")
                            .font(theme.typography.secondary)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: selectedPhoto) { _, newItem in
            Task {
                do {
                    if let data = try await newItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        avatarImage = Image(uiImage: uiImage)
                        avatarData = uiImage.jpegData(compressionQuality: 0.8)
                        showAvatarCrop = true
                    }
                } catch {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "Blip", category: "EditProfileView")
                        .warning("Failed to load photo: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Name Section

    private var nameSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text("Display Name")
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                TextField("Your name", text: $displayName)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .focused($focusedField, equals: .name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                    .padding(BlipSpacing.md)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
                    .accessibilityLabel("Display name")
            }
        }
    }

    // MARK: - Username Section

    private var usernameSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text("Username")
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                HStack(spacing: 0) {
                    Text("@")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.leading, BlipSpacing.md)

                    TextField("username", text: $username)
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
                .accessibilityLabel("Username")

                if let error = usernameError {
                    Text(error)
                        .font(theme.typography.caption)
                        .foregroundStyle(BlipColors.darkColors.statusRed)
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
                Text("Bio")
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
                    .accessibilityLabel("Bio, \(bio.count) of \(maxBioLength) characters")
                    .onChange(of: bio) { _, newValue in
                        if newValue.count > maxBioLength {
                            bio = String(newValue.prefix(maxBioLength))
                        }
                    }

                Text("\(bio.count)/\(maxBioLength)")
                    .font(theme.typography.caption)
                    .foregroundStyle(bio.count >= maxBioLength ? BlipColors.darkColors.statusAmber : theme.colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Email Section

    private var emailSection: some View {
        GlassCard(thickness: .regular) {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text("Email")
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    HStack(spacing: BlipSpacing.xs) {
                        Text(maskedEmail)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.mutedText)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BlipColors.adaptive.statusGreen)
                    }
                }

                Spacer()

                Button(action: { showEmailVerify = true }) {
                    Text("Change Email")
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
                .accessibilityLabel("Change email address")
            }
        }
    }

    /// Masked email display (e.g., "t***@gmail.com").
    private var maskedEmail: String {
        // Email hash is stored, not raw email — show masked placeholder.
        // In production, the raw email could be stored locally for display.
        "Verified email"
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
            usernameError = "Letters, numbers, and underscores only"
        } else if value.count < 3 {
            usernameError = "At least 3 characters"
        } else if value.count > maxUsernameLength {
            usernameError = "Maximum \(maxUsernameLength) characters"
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
        bio: "Festival lover."
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

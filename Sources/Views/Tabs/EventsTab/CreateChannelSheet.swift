import SwiftUI

private enum CreateChannelL10n {
    static let title = String(localized: "events.create_channel.title", defaultValue: "New channel")
    static let subtitle = String(localized: "events.create_channel.subtitle", defaultValue: "Spin up a local meet-up channel visible to anyone in mesh range.")
    static let namePlaceholder = String(localized: "events.create_channel.name.placeholder", defaultValue: "Channel name")
    static let nameLabel = String(localized: "events.create_channel.name.label", defaultValue: "Name")
    static let descriptionPlaceholder = String(localized: "events.create_channel.description.placeholder", defaultValue: "What's the vibe? Where? When?")
    static let descriptionLabel = String(localized: "events.create_channel.description.label", defaultValue: "Description (optional)")
    static let expiryLabel = String(localized: "events.create_channel.expiry.label", defaultValue: "Auto-expires in")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let create = String(localized: "events.create_channel.create", defaultValue: "Create")
    static let creating = String(localized: "events.create_channel.creating", defaultValue: "Creating...")
}

// MARK: - CreateChannelSheet

/// Sheet for creating a user-defined ad-hoc location channel (HEY-1245).
///
/// Form validation lives in `EventsViewModel.createAdHocChannel`; this view
/// only captures input and surfaces the resulting error inline.
struct CreateChannelSheet: View {

    /// ViewModel that performs persistence + mesh broadcast. Optional so the
    /// `#Preview` can render the sheet without wiring a live container.
    var eventsViewModel: EventsViewModel?

    /// Called with the newly created channel so the host can navigate into it.
    var onCreated: ((Channel) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var name: String = ""
    @State private var channelDescription: String = ""
    @State private var selectedExpiry: EventsViewModel.AdHocChannelExpiry = .fourHours
    @State private var inlineError: String?
    @State private var isSubmitting = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case description
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                    header

                    nameField
                    descriptionField
                    expiryPicker

                    if let inlineError {
                        errorBanner(inlineError)
                    }
                }
                .padding(BlipSpacing.md)
            }
            .background(backgroundLayer)
            .navigationTitle(CreateChannelL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CreateChannelL10n.cancel) {
                        dismiss()
                    }
                    .foregroundStyle(theme.colors.mutedText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            Skeleton(.inlineBusy())
                        } else {
                            Text(CreateChannelL10n.create)
                                .font(.custom(BlipFontName.semiBold, size: 15, relativeTo: .body))
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .foregroundStyle(
                        canSubmit && !isSubmitting
                            ? Color.blipAccentPurple
                            : theme.colors.mutedText
                    )
                }
            }
            .onAppear {
                focusedField = .name
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(CreateChannelL10n.subtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            HStack {
                Text(CreateChannelL10n.nameLabel)
                    .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                    .foregroundStyle(theme.colors.mutedText)
                Spacer()
                Text("\(name.count)/\(EventsViewModel.adHocChannelNameLimit)")
                    .font(.custom(BlipFontName.regular, size: 11, relativeTo: .caption2))
                    .foregroundStyle(
                        name.count > EventsViewModel.adHocChannelNameLimit
                            ? theme.colors.statusRed
                            : theme.colors.mutedText.opacity(0.7)
                    )
            }

            TextField(CreateChannelL10n.namePlaceholder, text: $name)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .description }
                .padding(BlipSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(fieldBorder(isFocused: focusedField == .name))
                .accessibilityLabel(CreateChannelL10n.nameLabel)
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            HStack {
                Text(CreateChannelL10n.descriptionLabel)
                    .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                    .foregroundStyle(theme.colors.mutedText)
                Spacer()
                Text("\(channelDescription.count)/\(EventsViewModel.adHocChannelDescriptionLimit)")
                    .font(.custom(BlipFontName.regular, size: 11, relativeTo: .caption2))
                    .foregroundStyle(
                        channelDescription.count > EventsViewModel.adHocChannelDescriptionLimit
                            ? theme.colors.statusRed
                            : theme.colors.mutedText.opacity(0.7)
                    )
            }

            ZStack(alignment: .topLeading) {
                if channelDescription.isEmpty {
                    Text(CreateChannelL10n.descriptionPlaceholder)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText.opacity(0.6))
                        .padding(.horizontal, BlipSpacing.sm + 2 + 4)
                        .padding(.vertical, BlipSpacing.sm + 2 + 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $channelDescription)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84, maxHeight: 120)
                    .focused($focusedField, equals: .description)
                    .padding(BlipSpacing.sm)
            }
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(fieldBorder(isFocused: focusedField == .description))
            .accessibilityLabel(CreateChannelL10n.descriptionLabel)
        }
    }

    private var expiryPicker: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(CreateChannelL10n.expiryLabel)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                .foregroundStyle(theme.colors.mutedText)

            HStack(spacing: BlipSpacing.xs) {
                ForEach(EventsViewModel.AdHocChannelExpiry.allCases) { expiry in
                    Button {
                        withAnimation(SpringConstants.accessibleSnappy) {
                            selectedExpiry = expiry
                        }
                    } label: {
                        Text(expiry.displayLabel)
                            .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                            .foregroundStyle(selectedExpiry == expiry ? .white : theme.colors.text)
                            .padding(.horizontal, BlipSpacing.sm + 2)
                            .padding(.vertical, BlipSpacing.sm)
                            .frame(maxWidth: .infinity)
                            .background(
                                selectedExpiry == expiry
                                    ? AnyShapeStyle(.blipAccentPurple)
                                    : AnyShapeStyle(.ultraThinMaterial)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expiry.displayLabel)
                    .accessibilityAddTraits(selectedExpiry == expiry ? .isSelected : [])
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(theme.typography.caption)
            Text(message)
                .font(theme.typography.caption)
        }
        .foregroundStyle(theme.colors.statusRed)
        .padding(.horizontal, BlipSpacing.sm)
        .padding(.vertical, BlipSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.sm, style: .continuous)
                .fill(theme.colors.statusRed.opacity(0.12))
        )
    }

    private func fieldBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
            .stroke(
                isFocused
                    ? Color.blipAccentPurple.opacity(0.3)
                    : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                lineWidth: isFocused ? 1.0 : BlipSizing.hairline
            )
            .animation(SpringConstants.gentleAnimation, value: isFocused)
    }

    private var backgroundLayer: some View {
        Rectangle()
            .fill(.thickMaterial)
            .ignoresSafeArea()
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= EventsViewModel.adHocChannelNameLimit
            && channelDescription.count <= EventsViewModel.adHocChannelDescriptionLimit
    }

    private func submit() {
        guard let eventsViewModel else {
            inlineError = "Events module not ready. Try again in a moment."
            return
        }

        isSubmitting = true
        inlineError = nil

        do {
            let channel = try eventsViewModel.createAdHocChannel(
                name: name,
                description: channelDescription.isEmpty ? nil : channelDescription,
                expiry: selectedExpiry
            )
            isSubmitting = false
            onCreated?(channel)
            dismiss()
        } catch let error as EventsViewModel.AdHocChannelError {
            inlineError = error.errorDescription
            isSubmitting = false
        } catch {
            inlineError = error.localizedDescription
            isSubmitting = false
        }
    }
}

// MARK: - Preview

#Preview("Create Channel Sheet") {
    CreateChannelSheet()
        .blipTheme()
}

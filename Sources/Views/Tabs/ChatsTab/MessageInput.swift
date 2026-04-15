import SwiftUI

private enum MessageInputL10n {
    static let editing = String(localized: "chat.input.editing", defaultValue: "Editing message")
    static let cancelEditing = String(localized: "chat.input.cancel_editing", defaultValue: "Cancel editing")
    static let dismissReply = String(localized: "chat.input.dismiss_reply", defaultValue: "Dismiss reply")
    static let addAttachment = String(localized: "chat.input.add_attachment", defaultValue: "Add attachment")
    static let attachmentTitle = String(localized: "chat.input.attachment.title", defaultValue: "Attachment")
    static let camera = String(localized: "common.camera", defaultValue: "Camera")
    static let photoLibrary = String(localized: "common.photo_library", defaultValue: "Photo Library")
    static let voiceNote = String(localized: "chat.input.attachment.voice_note", defaultValue: "Voice Note")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let placeholder = String(localized: "chat.input.placeholder", defaultValue: "Message")
    static let inputAccessibility = String(localized: "chat.input.accessibility_label", defaultValue: "Message input")
    static let pushToTalk = String(localized: "chat.input.ptt.accessibility_label", defaultValue: "Push to talk")
    static let pushToTalkHint = String(localized: "chat.input.ptt.accessibility_hint", defaultValue: "Double tap and hold to record, release to send")
    static let holdToTalk = String(localized: "chat.input.ptt.hold_accessibility_label", defaultValue: "Hold to talk")

    static func replyingTo(_ senderName: String) -> String {
        String(format: String(localized: "chat.input.replying_to", defaultValue: "Replying to %@"), locale: Locale.current, senderName)
    }
}

// MARK: - MessageInput

/// Glass text field with attachment button, morphing mic/send button, and PTT hold button.
struct MessageInput: View {

    @Binding var text: String

    /// Called when user taps the send button.
    var onSend: (String) -> Void = { _ in }

    /// Called when user taps the attachment button.
    var onAttachment: () -> Void = {}

    /// Called when user selects "Camera" from the attachment menu.
    var onCamera: () -> Void = {}

    /// Called when user selects "Photo Library" from the attachment menu.
    var onPhotoLibrary: () -> Void = {}

    /// Called when PTT begins (finger down).
    var onPTTStart: () -> Void = {}

    /// Called when PTT ends (finger up).
    var onPTTEnd: () -> Void = {}

    /// Reply context: sender name and preview text for the reply bar.
    var replyContext: (senderName: String, preview: String)?

    /// Called when user dismisses the reply bar.
    var onClearReply: () -> Void = {}

    /// Whether the input is in edit mode.
    var isEditing: Bool = false

    /// Called when user cancels edit mode.
    var onCancelEdit: () -> Void = {}

    /// Whether the WebSocket relay is connected (PTT requires relay — too large for BLE).
    var isRelayAvailable: Bool = true

    @State private var isSendMode = false
    @State private var isPTTActive = false
    @State private var showAttachmentMenu = false
    @FocusState private var isTextFieldFocused: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let maxTextHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            // Edit bar
            if isEditing {
                editBar
            }

            // Reply bar
            if let reply = replyContext, !isEditing {
                replyBar(senderName: reply.senderName, preview: reply.preview)
            }

            // Input bar
            HStack(alignment: .bottom, spacing: BlipSpacing.sm) {
                // Attachment button
                attachmentButton

                // Text field
                textField

                // Send / Mic / PTT area
                actionArea
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(inputBackground)
        }
    }

    // MARK: - Edit Bar

    private var editBar: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "pencil")
                .font(.custom(BlipFontName.medium, size: 14, relativeTo: .footnote))
                .foregroundStyle(Color.blipAccentPurple)

            Text(MessageInputL10n.editing)
                .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                .foregroundStyle(Color.blipAccentPurple)

            Spacer()

            Button {
                isTextFieldFocused = false
                onCancelEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.custom(BlipFontName.medium, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(MessageInputL10n.cancelEditing)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, BlipSpacing.md)
        .padding(.top, BlipSpacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(SpringConstants.gentleAnimation, value: isEditing)
    }

    // MARK: - Reply Bar

    private func replyBar(senderName: String, preview: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blipAccentPurple)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(MessageInputL10n.replyingTo(senderName))
                    .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                    .foregroundStyle(Color.blipAccentPurple)

                Text(preview)
                    .font(.custom(BlipFontName.regular, size: 13, relativeTo: .caption))
                    .foregroundStyle(theme.colors.mutedText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onClearReply()
            } label: {
                Image(systemName: "xmark")
                    .font(.custom(BlipFontName.medium, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(MessageInputL10n.dismissReply)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, BlipSpacing.md)
        .padding(.top, BlipSpacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(SpringConstants.gentleAnimation, value: replyContext?.senderName)
    }

    // MARK: - Attachment Button

    private var attachmentButton: some View {
        Button {
            isTextFieldFocused = false
            showAttachmentMenu = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.custom(BlipFontName.medium, size: 24, relativeTo: .title3))
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MessageInputL10n.addAttachment)
        .confirmationDialog(MessageInputL10n.attachmentTitle, isPresented: $showAttachmentMenu) {
            Button(MessageInputL10n.camera) { onCamera() }
            Button(MessageInputL10n.photoLibrary) { onPhotoLibrary() }
            Button(MessageInputL10n.voiceNote) { onAttachment() }
            Button(MessageInputL10n.cancel, role: .cancel) {}
        }
    }

    // MARK: - Text Field

    private var textField: some View {
        ZStack(alignment: .leading) {
            // Placeholder
            if text.isEmpty {
                Text(MessageInputL10n.placeholder)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.8))
                    .padding(.horizontal, BlipSpacing.sm + 4)
                    .allowsHitTesting(false)
            }

            // Text editor
            TextEditor(text: $text)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: maxTextHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, BlipSpacing.xs)
                .focused($isTextFieldFocused)
                .accessibilityLabel(MessageInputL10n.inputAccessibility)
                .onChange(of: text) { _, newValue in
                    withAnimation(SpringConstants.bouncyAnimation) {
                        isSendMode = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }
        }
        .padding(.vertical, BlipSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .stroke(
                    isTextFieldFocused
                        ? Color.blipAccentPurple.opacity(0.3)
                        : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                    lineWidth: isTextFieldFocused ? 1.0 : BlipSizing.hairline
                )
                .animation(SpringConstants.gentleAnimation, value: isTextFieldFocused)
        )
    }

    // MARK: - Action Area (Send / Mic / PTT)

    private var actionArea: some View {
        ZStack {
            if isSendMode {
                // Send button
                MorphingIconButton(isSendMode: $isSendMode) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isTextFieldFocused = false
                    if !SpringConstants.isReduceMotionEnabled {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    onSend(trimmed)
                    text = ""
                    onClearReply()
                }
            } else {
                // PTT hold button
                pttButton
            }
        }
        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
    }

    private var pttButton: some View {
        ZStack {
            // Ripple effect behind (hidden when relay unavailable)
            RippleEffect(isActive: $isPTTActive, ringCount: 3, color: .blipAccentPurple)
                .frame(width: 60, height: 60)
                .opacity(isRelayAvailable ? 1 : 0)

            Circle()
                .fill(isPTTActive ? LinearGradient.blipAccent : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom))
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.custom(BlipFontName.medium, size: 18, relativeTo: .body))
                        .foregroundStyle(
                            isPTTActive ? .white : theme.colors.mutedText
                        )
                )
                .overlay(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(isPTTActive ? 0 : 1)
                )
                .overlay(
                    Circle()
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.12)
                                : Color.black.opacity(0.08),
                            lineWidth: isPTTActive ? 0 : BlipSizing.hairline
                        )
                )
                .opacity(isRelayAvailable ? 1 : 0.35)
        }
        .accessibilityLabel(MessageInputL10n.pushToTalk)
        .accessibilityHint(MessageInputL10n.pushToTalkHint)
        .accessibilityAddTraits(.startsMediaSession)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isRelayAvailable else { return }
                    if !isPTTActive {
                        isPTTActive = true
                        if !SpringConstants.isReduceMotionEnabled {
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                        onPTTStart()
                    }
                }
                .onEnded { _ in
                    guard isRelayAvailable else { return }
                    isPTTActive = false
                    if !SpringConstants.isReduceMotionEnabled {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    }
                    onPTTEnd()
                }
        )
        .accessibilityLabel(MessageInputL10n.holdToTalk)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Background

    @ViewBuilder
    private var inputBackground: some View {
        Rectangle()
            .fill(.thickMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.04)
                    )
                    .frame(height: BlipSizing.hairline)
            }
    }
}

// MARK: - Preview

#Preview("Message Input - Empty") {
    struct InputPreview: View {
        @State private var text = ""
        var body: some View {
            VStack {
                Spacer()
                MessageInput(text: $text)
            }
            .background(GradientBackground())
            .environment(\.theme, Theme.shared)
        }
    }
    return InputPreview()
}

#Preview("Message Input - With Text") {
    struct InputPreview: View {
        @State private var text = "Are you at the stage?"
        var body: some View {
            VStack {
                Spacer()
                MessageInput(text: $text)
            }
            .background(GradientBackground())
            .environment(\.theme, Theme.shared)
        }
    }
    return InputPreview()
}

#Preview("Message Input - Light") {
    struct InputPreview: View {
        @State private var text = ""
        var body: some View {
            VStack {
                Spacer()
                MessageInput(text: $text)
            }
            .background(Color.white)
            .environment(\.theme, Theme.resolved(for: .light))
            .preferredColorScheme(.light)
        }
    }
    return InputPreview()
}

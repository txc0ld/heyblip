import SwiftUI

// MARK: - MessageInput

/// Glass text field with attachment button, morphing mic/send button, and PTT hold button.
struct MessageInput: View {

    @Binding var text: String

    /// Called when user taps the send button.
    var onSend: (String) -> Void = { _ in }

    /// Called when user taps the attachment button.
    var onAttachment: () -> Void = {}

    /// Called when PTT begins (finger down).
    var onPTTStart: () -> Void = {}

    /// Called when PTT ends (finger up).
    var onPTTEnd: () -> Void = {}

    /// Remaining message count. Nil means unlimited.
    var messagesRemaining: Int? = nil

    /// Called when the low balance pill is tapped.
    var onLowBalanceTap: () -> Void = {}

    @State private var isSendMode = false
    @State private var isPTTActive = false
    @State private var showAttachmentMenu = false
    @State private var textEditorHeight: CGFloat = 36
    @FocusState private var isTextFieldFocused: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let maxTextHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            // Low balance nudge
            if let remaining = messagesRemaining, remaining <= 5, remaining > 0 {
                lowBalancePill(remaining: remaining)
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

    // MARK: - Attachment Button

    private var attachmentButton: some View {
        Button {
            showAttachmentMenu = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add attachment")
        .confirmationDialog("Attachment", isPresented: $showAttachmentMenu) {
            Button("Camera") { onAttachment() }
            Button("Photo Library") { onAttachment() }
            Button("Voice Note") { onAttachment() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Text Field

    private var textField: some View {
        ZStack(alignment: .leading) {
            // Placeholder
            if text.isEmpty {
                Text("Message")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.6))
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
                        ? Color.blipAccentPurple.opacity(0.4)
                        : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                    lineWidth: BlipSizing.hairline
                )
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
                    onSend(trimmed)
                    text = ""
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
            // Ripple effect behind
            RippleEffect(isActive: $isPTTActive, ringCount: 3, color: .blipAccentPurple)
                .frame(width: 60, height: 60)

            Circle()
                .fill(isPTTActive ? LinearGradient.blipAccent : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom))
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .medium))
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
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPTTActive {
                        isPTTActive = true
                        onPTTStart()
                    }
                }
                .onEnded { _ in
                    isPTTActive = false
                    onPTTEnd()
                }
        )
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Low Balance Pill

    private func lowBalancePill(remaining: Int) -> some View {
        Button {
            onLowBalanceTap()
        } label: {
            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                Text("\(remaining) message\(remaining == 1 ? "" : "s") left")
                    .font(.custom(BlipFontName.medium, size: 12, relativeTo: .caption2))
            }
            .foregroundStyle(theme.colors.statusAmber)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.xs + 2)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(theme.colors.statusAmber.opacity(0.3), lineWidth: BlipSizing.hairline)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .padding(.bottom, BlipSpacing.xs)
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
                MessageInput(text: $text, messagesRemaining: 3)
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

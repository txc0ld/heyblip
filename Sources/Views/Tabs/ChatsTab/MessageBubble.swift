import SwiftUI

// MARK: - MessageBubble

/// Glass chat bubble with spring entrance animation.
/// Yours: right-aligned with accent-tinted glass.
/// Theirs: left-aligned with neutral glass.
/// Supports text, voice note, image, and reply quote.
/// Long-press context menu for reply, copy, edit, delete, report.
struct MessageBubble: View {

    let message: ChatMessage
    let index: Int

    /// Called when user taps reply in context menu.
    var onReply: (() -> Void)? = nil

    /// Called when user taps an image thumbnail to view full-screen.
    var onImageTap: (() -> Void)? = nil

    @State private var isVisible = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let maxBubbleWidth: CGFloat = 280

    var body: some View {
        HStack(alignment: .bottom, spacing: BlipSpacing.sm) {
            if message.isFromMe {
                Spacer(minLength: 60)
            } else {
                // Sender avatar for incoming messages
                AvatarView(
                    imageData: message.senderAvatarData,
                    name: message.senderName,
                    size: 28,
                    ringStyle: .none
                )
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: BlipSpacing.xs - 2) {
                // Sender name for group chats
                if !message.isFromMe && message.showSenderName {
                    Text(message.senderName)
                        .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                        .foregroundStyle(Color.blipAccentPurple)
                        .padding(.horizontal, BlipSpacing.sm)
                }

                // Bubble content
                bubbleContent
                    .contextMenu {
                        contextMenuItems
                    }
            }

            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .opacity(isVisible ? 1.0 : 0.0)
        .offset(x: isVisible ? 0 : (message.isFromMe ? 30 : -30))
        .onAppear {
            animateEntrance()
        }
    }

    // MARK: - Bubble Content

    private var bubbleContent: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: BlipSpacing.xs) {
            // Reply quote
            if let reply = message.replyPreview {
                replyQuote(reply)
            }

            // Message body
            Group {
                switch message.contentType {
                case .text:
                    textContent
                case .voiceNote:
                    voiceNoteContent
                case .image:
                    imageContent
                case .pttAudio:
                    voiceNoteContent
                }
            }

            // Timestamp + status row
            HStack(spacing: BlipSpacing.xs) {
                Text(message.formattedTime)
                    .font(.custom(BlipFontName.regular, size: 10, relativeTo: .caption2))
                    .foregroundStyle(
                        message.isFromMe
                            ? Color.white.opacity(0.6)
                            : theme.colors.mutedText.opacity(0.7)
                    )

                if message.isEdited {
                    Text("edited")
                        .font(.custom(BlipFontName.regular, size: 10, relativeTo: .caption2))
                        .foregroundStyle(
                            message.isFromMe
                                ? Color.white.opacity(0.5)
                                : theme.colors.mutedText.opacity(0.5)
                        )
                }

                if message.isFromMe {
                    StatusBadge(
                        status: message.deliveryStatus,
                        size: 10,
                        tintColor: message.deliveryStatus == .read
                            ? .white.opacity(0.8)
                            : .white.opacity(0.5)
                    )
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm + 2)
        .frame(maxWidth: maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
        .background(bubbleBackground)
        .clipShape(bubbleShape)
        .overlay(
            bubbleShape
                .stroke(borderColor, lineWidth: BlipSizing.hairline)
        )
    }

    // MARK: - Text Content

    private var textContent: some View {
        Text(message.text)
            .font(theme.typography.body)
            .foregroundStyle(message.isFromMe ? .white : theme.colors.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Voice Note Content

    private var voiceNoteContent: some View {
        VoiceNotePlayer(
            duration: message.voiceNoteDuration ?? 0,
            waveformSamples: message.waveformSamples,
            isFromMe: message.isFromMe
        )
        .frame(width: 200)
    }

    // MARK: - Image Content

    private var imageContent: some View {
        Group {
            if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                Button {
                    onImageTap?()
                } label: {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: BlipCornerRadius.sm, style: .continuous)
                    .fill(
                        message.isFromMe
                            ? Color.white.opacity(0.1)
                            : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                    )
                    .frame(width: 200, height: 150)
                    .overlay(
                        Image(systemName: "photo.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                message.isFromMe
                                    ? Color.white.opacity(0.4)
                                    : theme.colors.mutedText
                            )
                    )
            }
        }
    }

    // MARK: - Reply Quote

    private func replyQuote(_ preview: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blipAccentPurple)
                .frame(width: 3)

            Text(preview)
                .font(.custom(BlipFontName.regular, size: 13, relativeTo: .caption))
                .foregroundStyle(
                    message.isFromMe
                        ? Color.white.opacity(0.7)
                        : theme.colors.mutedText
                )
                .lineLimit(2)
        }
        .padding(BlipSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.sm, style: .continuous)
                .fill(
                    message.isFromMe
                        ? Color.white.opacity(0.1)
                        : (colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                )
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onReply?()
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
        }

        Button {
            UIPasteboard.general.string = message.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if message.isFromMe {
            Button {
                // Edit action handled by ViewModel
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                // Delete action handled by ViewModel
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        Divider()

        Button(role: .destructive) {
            // Report action handled by ViewModel
        } label: {
            Label("Report", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: - Styling

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isFromMe {
            // Glass material + accent gradient overlay for translucent outgoing
            ZStack {
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color(red: 0.40, green: 0.0, blue: 1.0).opacity(0.85),   // #6600FF
                        Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.85) // #8B5CF6
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            // Neutral glass surface for incoming
            ZStack {
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
            }
        }
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
    }

    private var borderColor: Color {
        if message.isFromMe {
            return Color.white.opacity(0.20)
        } else {
            return colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color.black.opacity(0.06)
        }
    }

    // MARK: - Animation

    private func animateEntrance() {
        if SpringConstants.isReduceMotionEnabled {
            withAnimation(.easeIn(duration: 0.15)) {
                isVisible = true
            }
        } else {
            withAnimation(SpringConstants.pageEntranceAnimation.delay(Double(min(index, 10)) * 0.03)) {
                isVisible = true
            }
        }
    }
}

// MARK: - ChatMessage (UI model)

/// Lightweight UI model for a single message. Populated by ViewModel.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let senderName: String
    let senderAvatarData: Data?
    let isFromMe: Bool
    let showSenderName: Bool
    let text: String
    let contentType: MessageType
    let deliveryStatus: StatusBadge.DeliveryStatus
    let timestamp: Date
    let isEdited: Bool
    let replyPreview: String?
    let imageData: Data?
    let voiceNoteDuration: TimeInterval?
    let waveformSamples: [Float]

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Sample Data

extension ChatMessage {
    static let sampleMessages: [ChatMessage] = [
        ChatMessage(
            id: UUID(), senderName: "Alice", senderAvatarData: nil,
            isFromMe: false, showSenderName: false,
            text: "Hey! Are you at the festival yet?",
            contentType: .text, deliveryStatus: .read,
            timestamp: Date().addingTimeInterval(-3600),
            isEdited: false, replyPreview: nil, imageData: nil,
            voiceNoteDuration: nil, waveformSamples: []
        ),
        ChatMessage(
            id: UUID(), senderName: "Me", senderAvatarData: nil,
            isFromMe: true, showSenderName: false,
            text: "Just arrived! Where are you?",
            contentType: .text, deliveryStatus: .read,
            timestamp: Date().addingTimeInterval(-3500),
            isEdited: false, replyPreview: nil, imageData: nil,
            voiceNoteDuration: nil, waveformSamples: []
        ),
        ChatMessage(
            id: UUID(), senderName: "Alice", senderAvatarData: nil,
            isFromMe: false, showSenderName: false,
            text: "I'm near the Pyramid Stage! Bicep is about to start",
            contentType: .text, deliveryStatus: .delivered,
            timestamp: Date().addingTimeInterval(-3400),
            isEdited: false, replyPreview: "Just arrived! Where are you?", imageData: nil,
            voiceNoteDuration: nil, waveformSamples: []
        ),
        ChatMessage(
            id: UUID(), senderName: "Me", senderAvatarData: nil,
            isFromMe: true, showSenderName: false,
            text: "On my way! Save me a spot",
            contentType: .text, deliveryStatus: .sent,
            timestamp: Date().addingTimeInterval(-60),
            isEdited: true, replyPreview: nil, imageData: nil,
            voiceNoteDuration: nil, waveformSamples: []
        ),
        ChatMessage(
            id: UUID(), senderName: "Alice", senderAvatarData: nil,
            isFromMe: false, showSenderName: false,
            text: "",
            contentType: .voiceNote, deliveryStatus: .delivered,
            timestamp: Date().addingTimeInterval(-30),
            isEdited: false, replyPreview: nil, imageData: nil,
            voiceNoteDuration: 12.5,
            waveformSamples: [0.2, 0.4, 0.6, 0.8, 0.5, 0.3, 0.7, 0.9, 0.4, 0.2, 0.5, 0.6]
        )
    ]
}

// MARK: - Preview

#Preview("Message Bubbles") {
    ScrollView {
        VStack(spacing: BlipSpacing.sm) {
            ForEach(Array(ChatMessage.sampleMessages.enumerated()), id: \.element.id) { index, message in
                MessageBubble(message: message, index: index)
            }
        }
        .padding(.vertical)
    }
    .background(GradientBackground())
    .environment(\.theme, Theme.shared)
}

#Preview("Message Bubble - Light") {
    ScrollView {
        VStack(spacing: BlipSpacing.sm) {
            ForEach(Array(ChatMessage.sampleMessages.enumerated()), id: \.element.id) { index, message in
                MessageBubble(message: message, index: index)
            }
        }
        .padding(.vertical)
    }
    .background(Color.white)
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

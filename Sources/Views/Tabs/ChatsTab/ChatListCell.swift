import SwiftUI

// MARK: - ChatListCell

/// A single conversation row in the chat list.
/// Glass card with avatar, name, last message preview, timestamp, unread badge.
/// Only exposes swipe actions that are wired in the current build.
struct ChatListCell: View {

    let conversation: ConversationPreview
    let index: Int
    var onTap: () -> Void = {}
    var onToggleMute: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BlipSpacing.md) {
                // Avatar
                AvatarView(
                    imageData: conversation.avatarData,
                    name: conversation.displayName,
                    size: BlipSizing.avatarMedium,
                    ringStyle: conversation.ringStyle,
                    showOnlineIndicator: conversation.isOnline
                )

                // Text content
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    HStack {
                        Text(conversation.displayName)
                            .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                            .foregroundStyle(theme.colors.text)
                            .lineLimit(1)

                        Spacer()

                        Text(conversation.formattedTimestamp)
                            .font(theme.typography.caption)
                            .foregroundStyle(
                                conversation.unreadCount > 0
                                    ? Color.blipAccentPurple
                                    : theme.colors.tertiaryText
                            )
                    }

                    HStack {
                        // Last message preview
                        HStack(spacing: BlipSpacing.xs) {
                            if conversation.isFromMe {
                                StatusBadge(
                                    status: conversation.deliveryStatus,
                                    size: 11
                                )
                            }

                            if let messageIcon = conversation.messageTypeIcon {
                                Image(systemName: messageIcon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.colors.mutedText)
                            }

                            Text(conversation.lastMessagePreview)
                                .font(theme.typography.secondary)
                                .foregroundStyle(theme.colors.mutedText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Unread badge
                        if conversation.unreadCount > 0 {
                            unreadBadge
                        }
                    }
                }
            }
            .padding(.vertical, BlipSpacing.sm + 2)
            .padding(.horizontal, BlipSpacing.md)
            .background(cellBackground)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.04),
                        lineWidth: BlipSizing.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .staggeredReveal(index: index)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onToggleMute {
                Button(action: onToggleMute) {
                    Label(
                        conversation.isMuted ? "Unmute" : "Mute",
                        systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill"
                    )
                }
                .tint(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Unread Badge

    private var unreadBadge: some View {
        Text(conversation.unreadCount > 99 ? "99+" : "\(conversation.unreadCount)")
            .font(.custom(BlipFontName.bold, size: 11, relativeTo: .caption2))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.blipAccentPurple)
            )
            .contentTransition(.numericText())
    }

    // MARK: - Background

    @ViewBuilder
    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
            .fill(.ultraThinMaterial)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [conversation.displayName]
        if conversation.unreadCount > 0 {
            parts.append("\(conversation.unreadCount) unread")
        }
        parts.append(conversation.lastMessagePreview)
        parts.append(conversation.formattedTimestamp)
        return parts.joined(separator: ", ")
    }
}

// MARK: - ConversationPreview (UI model)

/// Lightweight UI model for the chat list. Populated by ViewModel from SwiftData Channel/Message.
struct ConversationPreview: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let avatarData: Data?
    let lastMessagePreview: String
    let timestamp: Date
    let unreadCount: Int
    let isOnline: Bool
    let isPinned: Bool
    let isMuted: Bool
    let isFromMe: Bool
    let deliveryStatus: StatusBadge.DeliveryStatus
    let ringStyle: AvatarView.RingStyle
    let messageType: MessageType

    var formattedTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: timestamp)
        }
    }

    var messageTypeIcon: String? {
        switch messageType {
        case .voiceNote: return "mic.fill"
        case .image: return "photo.fill"
        case .pttAudio: return "waveform"
        case .text: return nil
        }
    }
}

// MARK: - Preview Data

extension ConversationPreview {
    static let sampleConversations: [ConversationPreview] = [
        ConversationPreview(
            id: UUID(),
            displayName: "Alice",
            avatarData: nil,
            lastMessagePreview: "Are you at the Pyramid Stage?",
            timestamp: Date().addingTimeInterval(-120),
            unreadCount: 3,
            isOnline: true,
            isPinned: true,
            isMuted: false,
            isFromMe: false,
            deliveryStatus: .delivered,
            ringStyle: .friend,
            messageType: .text
        ),
        ConversationPreview(
            id: UUID(),
            displayName: "Festival Squad",
            avatarData: nil,
            lastMessagePreview: "Voice note",
            timestamp: Date().addingTimeInterval(-3600),
            unreadCount: 0,
            isOnline: false,
            isPinned: false,
            isMuted: false,
            isFromMe: true,
            deliveryStatus: .read,
            ringStyle: .none,
            messageType: .voiceNote
        ),
        ConversationPreview(
            id: UUID(),
            displayName: "Bob",
            avatarData: nil,
            lastMessagePreview: "Photo",
            timestamp: Date().addingTimeInterval(-86400),
            unreadCount: 1,
            isOnline: false,
            isPinned: false,
            isMuted: true,
            isFromMe: false,
            deliveryStatus: .sent,
            ringStyle: .nearby,
            messageType: .image
        ),
        ConversationPreview(
            id: UUID(),
            displayName: "Charlie",
            avatarData: nil,
            lastMessagePreview: "Let's meet at the food court",
            timestamp: Date().addingTimeInterval(-172800),
            unreadCount: 0,
            isOnline: false,
            isPinned: false,
            isMuted: false,
            isFromMe: true,
            deliveryStatus: .delivered,
            ringStyle: .subscriber,
            messageType: .text
        )
    ]
}

// MARK: - Preview

#Preview("Chat List Cell") {
    ZStack {
        GradientBackground()
            .ignoresSafeArea()

        ScrollView {
            LazyVStack(spacing: BlipSpacing.sm) {
                ForEach(
                    Array(ConversationPreview.sampleConversations.enumerated()),
                    id: \.element.id
                ) { index, conversation in
                    ChatListCell(conversation: conversation, index: index)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
        }
    }
    .environment(\.theme, Theme.shared)
}

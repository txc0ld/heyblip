import SwiftUI

// MARK: - MessageSearchResult

/// Lightweight value type representing a search hit across channels.
struct MessageSearchResult: Identifiable {
    let id: UUID
    let messageID: UUID
    let channelID: UUID
    let channelName: String
    let senderName: String?
    let messageText: String
    let timestamp: Date

    var formattedDate: String {
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
}

// MARK: - MessageSearchResultRow

/// A single search result row with channel context and highlighted match text.
struct MessageSearchResultRow: View {

    let result: MessageSearchResult
    let query: String

    @Environment(\.theme) private var theme

    var body: some View {
        GlassCard(
            thickness: .ultraThin,
            cornerRadius: BlipCornerRadius.xl,
            padding: .blipContent
        ) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                // Channel name + timestamp
                HStack {
                    Text(result.channelName)
                        .font(.custom(BlipFontName.semiBold, size: 13, relativeTo: .footnote))
                        .foregroundStyle(Color.blipAccentPurple)

                    Spacer()

                    Text(result.formattedDate)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.tertiaryText)
                }

                // Sender name
                if let senderName = result.senderName {
                    Text(senderName)
                        .font(.custom(BlipFontName.bold, size: 15, relativeTo: .body))
                        .foregroundStyle(theme.colors.text)
                }

                // Message text with highlighted match
                highlightedText(result.messageText, query: query)
                    .font(.custom(BlipFontName.regular, size: 14, relativeTo: .body))
                    .foregroundStyle(theme.colors.mutedText)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Highlighted Text

    /// Builds concatenated `Text` views that bold the matching substring in accent purple.
    private func highlightedText(_ text: String, query: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return Text(text)
        }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = trimmedQuery.lowercased()

        guard let range = lowercasedText.range(of: lowercasedQuery) else {
            return Text(text)
        }

        let beforeMatch = String(text[text.startIndex..<range.lowerBound])
        let matchText = String(text[range.lowerBound..<range.upperBound])
        let afterMatch = String(text[range.upperBound..<text.endIndex])

        return Text(beforeMatch)
            + Text(matchText)
                .font(.custom(BlipFontName.bold, size: 14, relativeTo: .body))
                .foregroundColor(Color.blipAccentPurple)
            + Text(afterMatch)
    }
}

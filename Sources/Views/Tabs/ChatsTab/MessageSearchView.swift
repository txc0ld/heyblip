import SwiftUI
import SwiftData

private enum MessageSearchL10n {
    static let title = String(localized: "chat.search.title", defaultValue: "Search Messages")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let placeholder = String(localized: "chat.search.placeholder", defaultValue: "Search messages...")
    static let clear = String(localized: "chat.search.clear", defaultValue: "Clear search")
    static let emptyTitle = String(localized: "chat.search.empty.title", defaultValue: "Search across all channels")
    static let emptySubtitle = String(localized: "chat.search.empty.subtitle", defaultValue: "Find messages by content from\nany conversation.")
    static let searching = String(localized: "chat.search.loading", defaultValue: "Searching...")
    static let noResultsSubtitle = String(localized: "chat.search.no_results.subtitle", defaultValue: "Try a different search term.")
    static let fallbackChannel = String(localized: "chat.search.channel.fallback", defaultValue: "Chat")

    static func noResults(_ query: String) -> String {
        String(format: String(localized: "chat.search.no_results.title", defaultValue: "No results for \"%@\""), locale: Locale.current, query)
    }

    static func resultCount(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "chat.search.result_count.singular", defaultValue: "1 result")
        }
        return String(format: String(localized: "chat.search.result_count.plural", defaultValue: "%d results"), locale: Locale.current, count)
    }

    static func resultAccessibility(sender: String?, channel: String, message: String, date: String) -> String {
        if let sender {
            return String(
                format: String(localized: "chat.search.result.accessibility_label.with_sender", defaultValue: "%@ in %@: %@, %@"),
                locale: Locale.current,
                sender, channel, message, date
            )
        }
        return String(
            format: String(localized: "chat.search.result.accessibility_label", defaultValue: "In %@: %@, %@"),
            locale: Locale.current,
            channel, message, date
        )
    }
}

// MARK: - MessageSearchView

/// Full-screen sheet for searching message content across all channels.
/// Queries SwiftData for text messages and filters in-memory by payload content.
struct MessageSearchView: View {

    var onResultTap: ((UUID) -> Void)?

    @State private var searchText = ""
    @State private var searchResults: [MessageSearchResult] = []
    @State private var isSearching = false
    @FocusState private var isFieldFocused: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Debounce task handle
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.top, BlipSpacing.sm)
                        .padding(.bottom, BlipSpacing.md)

                    contentArea
                }
            }
            .navigationTitle(MessageSearchL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MessageSearchL10n.cancel) { dismiss() }
                        .foregroundStyle(Color.blipAccentPurple)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onChange(of: searchText) { _, newValue in
            debounceSearch(query: newValue)
        }
        .onAppear {
            isFieldFocused = true
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(theme.typography.footnote)
                .foregroundStyle(isFieldFocused ? Color.blipAccentPurple : theme.colors.mutedText)

            TextField(MessageSearchL10n.placeholder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.custom(BlipFontName.regular, size: 16, relativeTo: .body))
                .foregroundStyle(theme.colors.text)
                .focused($isFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(theme.typography.callout)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MessageSearchL10n.clear)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .stroke(
                    isFieldFocused
                        ? Color.blipAccentPurple.opacity(0.5)
                        : Color.clear,
                    lineWidth: BlipSizing.hairline
                )
        )
        .animation(SpringConstants.gentleAnimation, value: isFieldFocused)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyPromptState
        } else if isSearching {
            searchingState
        } else if searchResults.isEmpty {
            noResultsState
        } else {
            resultsList
        }
    }

    // MARK: - States

    private var emptyPromptState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))
            Text(MessageSearchL10n.emptyTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text(MessageSearchL10n.emptySubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .staggeredReveal(index: 0)
    }

    private var searchingState: some View {
        VStack(spacing: BlipSpacing.lg) {
            // Layout-matching skeletons mirror the eventual list of result rows.
            // Keeping the "Searching…" caption gives the loading state a voice
            // — the rows alone read as "results loaded but empty."
            Skeleton.list(of: .chatRow, count: 4)
                .padding(.horizontal, BlipSpacing.md)
            Text(MessageSearchL10n.searching)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BlipSpacing.lg)
    }

    private var noResultsState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))
            Text(MessageSearchL10n.noResults(searchText))
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text(MessageSearchL10n.noResultsSubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .staggeredReveal(index: 0)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: BlipSpacing.sm) {
                HStack {
                    Text(MessageSearchL10n.resultCount(searchResults.count))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                    Spacer()
                }
                .padding(.horizontal, BlipSpacing.xs)

                ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, result in
                    Button {
                        dismiss()
                        onResultTap?(result.channelID)
                    } label: {
                        MessageSearchResultRow(result: result, query: searchText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MessageSearchL10n.resultAccessibility(
                        sender: result.senderName,
                        channel: result.channelName,
                        message: result.messageText,
                        date: result.formattedDate
                    ))
                    .staggeredReveal(index: index)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.bottom, BlipSpacing.xl)
        }
    }

    // MARK: - Search Logic

    private func debounceSearch(query: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                DebugLogger.shared.log("SEARCH", "Debounce cancelled: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true

        do {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.typeRaw == "text" }
            )
            descriptor.fetchLimit = 100

            let messages = try modelContext.fetch(descriptor)
                .sorted { $0.createdAt > $1.createdAt }
            searchResults = messages.compactMap { message in
                guard let text = String(data: message.rawPayload, encoding: .utf8),
                      text.localizedCaseInsensitiveContains(query) else { return nil }
                return MessageSearchResult(
                    id: message.id,
                    messageID: message.id,
                    channelID: message.channel?.id ?? UUID(),
                    channelName: message.channel?.name ?? MessageSearchL10n.fallbackChannel,
                    senderName: message.sender?.resolvedDisplayName ?? message.sender?.username,
                    messageText: text,
                    timestamp: message.createdAt
                )
            }
        } catch {
            DebugLogger.shared.log("SEARCH", "Search query failed: \(error)")
            searchResults = []
        }
        isSearching = false
    }
}

// MARK: - Previews

#Preview("Message Search") {
    MessageSearchView()
        .blipTheme()
}

import SwiftUI

private enum AddFriendByUsernameL10n {
    static let navigationTitle = String(localized: "profile.add_friend.title", defaultValue: "Add Friend")
    static let done = String(localized: "common.done", defaultValue: "Done")
    static let usernamePlaceholder = String(localized: "profile.add_friend.username.placeholder", defaultValue: "Enter username")
    static let searchAccessibilityLabel = String(localized: "profile.add_friend.search.accessibility_label", defaultValue: "Search for user")
    static let emptyTitle = String(localized: "profile.add_friend.empty.title", defaultValue: "Search by username")
    static let emptySubtitle = String(localized: "profile.add_friend.empty.subtitle", defaultValue: "Find friends even when they're not nearby.\nThey'll get your request next time they're on the mesh.")
    static let searching = String(localized: "profile.add_friend.search.loading", defaultValue: "Searching...")

    static func noUserFound(_ username: String) -> String {
        String(
            format: String(localized: "profile.add_friend.error.not_found", defaultValue: "No user found with username \"%@\""),
            locale: Locale.current,
            username
        )
    }

    static func searchFailed(_ error: String) -> String {
        String(
            format: String(localized: "profile.add_friend.error.search_failed", defaultValue: "Search failed: %@"),
            locale: Locale.current,
            error
        )
    }

    static func requestSent(_ username: String) -> String {
        String(
            format: String(localized: "profile.add_friend.success.request_sent", defaultValue: "Friend request sent to %@!"),
            locale: Locale.current,
            username
        )
    }

    static func sendFailed(_ error: String) -> String {
        String(
            format: String(localized: "profile.add_friend.error.send_failed", defaultValue: "Failed to send: %@"),
            locale: Locale.current,
            error
        )
    }
}

// MARK: - Add Friend by Username Sheet

/// Sheet for searching and adding a friend by their Blip username.
/// Used for remote DM testing when users aren't in Bluetooth range.
struct AddFriendByUsernameSheet: View {

    /// Optional pre-filled username (e.g. from QR code scan or deep link).
    private let initialUsername: String

    init(initialUsername: String = "") {
        self.initialUsername = initialUsername
    }

    @State private var username = ""
    @State private var lookupResult: UserSyncService.RemoteLookupResult?
    @State private var isSearching = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @FocusState private var isFieldFocused: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                VStack(spacing: BlipSpacing.lg) {
                    searchField
                    resultArea
                    Spacer()
                }
                .padding(BlipSpacing.md)
            }
            .navigationTitle(AddFriendByUsernameL10n.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AddFriendByUsernameL10n.done) { dismiss() }
                        .foregroundStyle(.blipAccentPurple)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            if !initialUsername.isEmpty {
                username = initialUsername
                Task { await search() }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: BlipSpacing.sm) {
            TextField(AddFriendByUsernameL10n.usernamePlaceholder, text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .font(.custom(BlipFontName.regular, size: 16, relativeTo: .body))
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.md)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.md)
                        .stroke(
                            isFieldFocused
                                ? Color.blipAccentPurple.opacity(0.6)
                                : Color.white.opacity(0.08),
                            lineWidth: isFieldFocused ? 1.5 : BlipSizing.hairline
                        )
                )
                .animation(SpringConstants.accessibleSnappy, value: isFieldFocused)
                .onSubmit { Task { await search() } }

            Button {
                Task { await search() }
            } label: {
                if isSearching {
                    ProgressView()
                        .tint(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                        .background(
                            LinearGradient.blipAccent,
                            in: RoundedRectangle(cornerRadius: BlipCornerRadius.md)
                        )
                }
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            .accessibilityLabel(AddFriendByUsernameL10n.searchAccessibilityLabel)
        }
    }

    // MARK: - Result Area

    @ViewBuilder
    private var resultArea: some View {
        if let error = errorMessage {
            AddFriendSheetComponents.errorCard(message: error, theme: theme)
                .transition(.scale.combined(with: .opacity))
                .animation(SpringConstants.accessiblePageEntrance, value: errorMessage)
        } else if let success = successMessage {
            AddFriendSheetComponents.successCard(message: success, theme: theme)
                .transition(.scale.combined(with: .opacity))
                .animation(SpringConstants.accessiblePageEntrance, value: successMessage)
        } else if isSearching {
            searchingIndicator
                .transition(.opacity)
        } else if let result = lookupResult {
            AddFriendSheetComponents.resultCard(
                for: result,
                isSending: isSending,
                theme: theme,
                onSendRequest: { Task { await sendRequest(to: result) } }
            )
            .transition(.scale.combined(with: .opacity))
            .animation(SpringConstants.accessiblePageEntrance, value: lookupResult?.id)
        } else {
            emptyState
                .transition(.opacity)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.md) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(theme.colors.mutedText)
            Text(AddFriendByUsernameL10n.emptyTitle)
                .font(theme.typography.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.colors.text)
            Text(AddFriendByUsernameL10n.emptySubtitle)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, BlipSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Searching Indicator

    private var searchingIndicator: some View {
        VStack(spacing: BlipSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.blipAccentPurple)
            Text(AddFriendByUsernameL10n.searching)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .padding(.vertical, BlipSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func search() async {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        successMessage = nil
        lookupResult = nil

        do {
            let result = try await UserSyncService().lookupUser(username: trimmed)
            if let result {
                lookupResult = result
            } else {
                errorMessage = AddFriendByUsernameL10n.noUserFound(trimmed)
            }
        } catch {
            errorMessage = AddFriendByUsernameL10n.searchFailed(error.localizedDescription)
        }

        isSearching = false
    }

    private func sendRequest(to result: UserSyncService.RemoteLookupResult) async {
        isSending = true
        errorMessage = nil

        do {
            try await coordinator.messageService?.sendFriendRequestByUsername(result.username)
            successMessage = AddFriendByUsernameL10n.requestSent(result.username)
            lookupResult = nil
        } catch {
            errorMessage = AddFriendByUsernameL10n.sendFailed(error.localizedDescription)
        }

        isSending = false
    }
}

// MARK: - Preview

#Preview("Add Friend") {
    AddFriendByUsernameSheet()
        .blipTheme()
}

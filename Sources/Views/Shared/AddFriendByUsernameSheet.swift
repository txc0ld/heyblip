import SwiftUI

// MARK: - Add Friend by Username Sheet

/// Sheet for searching and adding a friend by their Blip username.
/// Used for remote DM testing when users aren't in Bluetooth range.
struct AddFriendByUsernameSheet: View {

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
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.blipAccentPurple)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: BlipSpacing.sm) {
            TextField("Enter username", text: $username)
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
        }
    }

    // MARK: - Result Area

    @ViewBuilder
    private var resultArea: some View {
        if let error = errorMessage {
            errorCard(message: error)
                .transition(.scale.combined(with: .opacity))
        } else if let success = successMessage {
            successCard(message: success)
                .transition(.scale.combined(with: .opacity))
        } else if isSearching {
            searchingIndicator
                .transition(.opacity)
        } else if let result = lookupResult {
            resultCard(for: result)
                .transition(.scale.combined(with: .opacity))
        } else {
            emptyState
                .transition(.opacity)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.md) {
            Image(systemName: "person.crop.circle.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(theme.colors.mutedText)
            Text("Search by username")
                .font(theme.typography.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.colors.text)
            Text("Find friends even when they're not nearby.\nThey'll get your request next time they're on the mesh.")
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
            Text("Searching...")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .padding(.vertical, BlipSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        GlassCard(thickness: .ultraThin) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colors.statusAmber)
                Text(message)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: errorMessage)
    }

    // MARK: - Success Card

    private func successCard(message: String) -> some View {
        GlassCard(thickness: .ultraThin) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(theme.typography.secondary)
                    .foregroundStyle(.green)
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: successMessage)
    }

    // MARK: - Result Card

    private func resultCard(for result: UserSyncService.RemoteLookupResult) -> some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                HStack(spacing: BlipSpacing.sm) {
                    AvatarView(
                        imageData: nil,
                        name: result.username,
                        size: BlipSizing.avatarMedium,
                        ringStyle: result.isVerified ? .subscriber : .none,
                        showOnlineIndicator: false
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: BlipSpacing.xs) {
                            Text(result.username)
                                .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                                .foregroundStyle(theme.colors.text)

                            if result.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.blipAccentPurple)
                            }
                        }

                        Text(result.noisePublicKey != nil ? "Keys available" : "No encryption keys")
                            .font(theme.typography.caption)
                            .foregroundStyle(result.noisePublicKey != nil ? .green : theme.colors.mutedText)
                    }

                    Spacer()
                }

                Button {
                    Task { await sendRequest(to: result) }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "person.badge.plus")
                            Text("Send Friend Request")
                        }
                    }
                    .font(.custom(BlipFontName.semiBold, size: 15, relativeTo: .body))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.sm + 2)
                    .background(
                        LinearGradient.blipAccent,
                        in: RoundedRectangle(cornerRadius: BlipCornerRadius.lg)
                    )
                    .opacity(result.noisePublicKey == nil ? 0.5 : 1.0)
                }
                .disabled(isSending || result.noisePublicKey == nil)
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: lookupResult?.id)
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
                errorMessage = "No user found with username \"\(trimmed)\""
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }

        isSearching = false
    }

    private func sendRequest(to result: UserSyncService.RemoteLookupResult) async {
        isSending = true
        errorMessage = nil

        do {
            try await coordinator.messageService?.sendFriendRequestByUsername(result.username)
            successMessage = "Friend request sent to \(result.username)!"
            lookupResult = nil
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }

        isSending = false
    }
}

// MARK: - Preview

#Preview("Add Friend by Username") {
    AddFriendByUsernameSheet()
        .environment(\.theme, Theme.shared)
}

#Preview("Empty State") {
    AddFriendByUsernameSheet()
        .environment(\.theme, Theme.shared)
        .preferredColorScheme(.dark)
}

#Preview("Light Mode") {
    AddFriendByUsernameSheet()
        .environment(\.theme, Theme.shared)
        .preferredColorScheme(.light)
}

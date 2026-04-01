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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                VStack(spacing: BlipSpacing.lg) {
                    searchField
                    resultCard
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
                .font(.custom(BlipFontName.regular, size: 16, relativeTo: .body))
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.md)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.md)
                        .stroke(Color.white.opacity(0.08), lineWidth: BlipSizing.hairline)
                )
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
                        .background(Color.blipAccentPurple, in: RoundedRectangle(cornerRadius: BlipCornerRadius.md))
                }
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
    }

    // MARK: - Result Card

    @ViewBuilder
    private var resultCard: some View {
        if let error = errorMessage {
            GlassCard(thickness: .ultraThin) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.colors.statusAmber)
                    Text(error)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        } else if let success = successMessage {
            GlassCard(thickness: .ultraThin) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(success)
                        .font(theme.typography.secondary)
                        .foregroundStyle(.green)
                }
            }
        } else if let result = lookupResult {
            GlassCard(thickness: .regular) {
                VStack(spacing: BlipSpacing.md) {
                    HStack(spacing: BlipSpacing.sm) {
                        // Avatar placeholder
                        Circle()
                            .fill(Color.blipAccentPurple.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text(String(result.username.prefix(1)).uppercased())
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.blipAccentPurple)
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
                        .background(Color.blipAccentPurple, in: RoundedRectangle(cornerRadius: BlipCornerRadius.md))
                    }
                    .disabled(isSending || result.noisePublicKey == nil)
                }
            }
        }
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

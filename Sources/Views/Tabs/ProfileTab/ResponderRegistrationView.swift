import SwiftUI
import CryptoKit

// MARK: - ResponderRegistrationView

/// Registration form for medical responders at events.
/// Access codes are provided by event organizers; validation is local-only for now.
struct ResponderRegistrationView: View {

    @State private var callsign: String = ""
    @State private var accessCode: String = ""
    @State private var isSubmitting = false

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var coordinator

    private var isValid: Bool {
        callsign.trimmingCharacters(in: .whitespaces).count >= 2
            && !accessCode.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: BlipSpacing.lg) {
                        headerSection
                        formSection
                        submitButton
                    }
                    .padding(BlipSpacing.md)
                }
            }
            .navigationTitle("Responder Registration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
            VStack(spacing: BlipSpacing.md) {
                Image(systemName: "cross.circle.fill")
                    .font(theme.typography.display)
                    .foregroundStyle(.blipAccentPurple)

                Text("Medical Responder Registration")
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                Text("Register to receive and respond to SOS alerts at events. You'll need an access code from the event organizer.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, BlipSpacing.sm)
        }
    }

    // MARK: - Form

    private var formSection: some View {
        GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text("Callsign")
                        .font(theme.typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.mutedText)

                    TextField("e.g. Medic-7", text: $callsign)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: callsign) { _, newValue in
                            if newValue.count > 20 {
                                callsign = String(newValue.prefix(20))
                            }
                        }
                        .padding(BlipSpacing.sm)
                        .background(theme.colors.hover)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md))
                }

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text("Access Code")
                        .font(theme.typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.mutedText)

                    SecureField("Provided by event organizer", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(BlipSpacing.sm)
                        .background(theme.colors.hover)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md))
                }
            }
        }
    }

    // MARK: - Submit

    private var submitButton: some View {
        Button(action: register) {
            HStack(spacing: BlipSpacing.sm) {
                if isSubmitting {
                    Skeleton(.inlineBusy(tint: .white))
                } else {
                    Image(systemName: "checkmark.shield.fill")
                }
                Text("Register as Responder")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl)
                    .fill(isValid ? LinearGradient.blipAccent : LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing))
            )
        }
        .disabled(!isValid || isSubmitting)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("Register as Responder")
    }

    // MARK: - Action

    private func register() {
        guard isValid else { return }
        isSubmitting = true

        let trimmedCallsign = callsign.trimmingCharacters(in: .whitespaces)
        let hash = SHA256.hash(data: Data(accessCode.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        Task {
            await coordinator.sosViewModel?.registerResponder(
                callsign: trimmedCallsign,
                accessCodeHash: hash
            )
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview("Responder Registration") {
    ResponderRegistrationView()
        .preferredColorScheme(.dark)
        .blipTheme()
        .environment(AppCoordinator())
}

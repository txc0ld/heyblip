import SwiftUI

// MARK: - FestiChatWordmark

/// The FestiChat logo wordmark for splash screen and branding.
/// Uses Plus Jakarta Sans Bold with accent purple gradient.
struct FestiChatWordmark: View {

    let fontSize: CGFloat
    let showTagline: Bool

    @Environment(\.theme) private var theme

    init(fontSize: CGFloat = 32, showTagline: Bool = true) {
        self.fontSize = fontSize
        self.showTagline = showTagline
    }

    var body: some View {
        VStack(spacing: 8) {
            // Main wordmark
            HStack(spacing: 0) {
                Text("Festi")
                    .font(.custom(FCFontName.bold, size: fontSize))
                    .foregroundStyle(.white)

                Text("Chat")
                    .font(.custom(FCFontName.bold, size: fontSize))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.fcAccentPurple, Color(red: 0.55, green: 0.15, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            if showTagline {
                Text("Chat at festivals, even without signal")
                    .font(.custom(FCFontName.regular, size: fontSize * 0.4))
                    .foregroundStyle(theme.colors.mutedText)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FestiChat")
    }
}

// MARK: - Preview

#Preview("Wordmark - Large") {
    ZStack {
        GradientBackground()
        FestiChatWordmark(fontSize: 40)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Wordmark - Small") {
    ZStack {
        GradientBackground()
        FestiChatWordmark(fontSize: 24, showTagline: false)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Wordmark - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        FestiChatWordmark(fontSize: 32)
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

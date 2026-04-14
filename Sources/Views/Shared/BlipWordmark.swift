import SwiftUI

private enum BlipWordmarkL10n {
    static let hey = "Hey"
    static let blip = "Blip"
    static let tagline = String(localized: "brand.wordmark.tagline", defaultValue: "Chat at events, even without signal")
    static let accessibility = "HeyBlip"
}

// MARK: - BlipWordmark

/// The Blip logo wordmark for splash screen and branding.
/// Uses Plus Jakarta Sans Bold with accent purple gradient.
struct BlipWordmark: View {

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
                Text(BlipWordmarkL10n.hey)
                    .font(.custom(BlipFontName.bold, size: fontSize))
                    .foregroundStyle(.white)

                Text(BlipWordmarkL10n.blip)
                    .font(.custom(BlipFontName.bold, size: fontSize))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blipAccentPurple, Color(red: 0.55, green: 0.15, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            if showTagline {
                Text(BlipWordmarkL10n.tagline)
                    .font(.custom(BlipFontName.regular, size: fontSize * 0.4))
                    .foregroundStyle(theme.colors.mutedText)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BlipWordmarkL10n.accessibility)
    }
}

// MARK: - Preview

#Preview("Wordmark - Large") {
    ZStack {
        GradientBackground()
        BlipWordmark(fontSize: 40)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Wordmark - Small") {
    ZStack {
        GradientBackground()
        BlipWordmark(fontSize: 24, showTagline: false)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Wordmark - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        BlipWordmark(fontSize: 32)
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}

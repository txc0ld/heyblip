import SwiftUI

// MARK: - VerifiedBadge

/// Meta/Instagram-style verified badge — blue star-edged seal with white checkmark.
/// Uses SF Symbol `checkmark.seal.fill` for the jagged/star edges.
struct VerifiedBadge: View {

    let size: CGFloat
    @Environment(\.theme) private var theme

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(badgeFont)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .blue)
            .accessibilityLabel("Verified")
    }

    private var badgeFont: Font {
        if size >= 22 {
            return theme.typography.title3
        }
        if size >= 16 {
            return theme.typography.callout
        }
        return theme.typography.caption
    }
}

// MARK: - Preview

#Preview("Verified Badge") {
    HStack(spacing: 20) {
        VerifiedBadge(size: 12)
        VerifiedBadge(size: 16)
        VerifiedBadge(size: 20)
        VerifiedBadge(size: 24)
    }
    .padding()
    .background(.black)
}

import SwiftUI

// MARK: - VerifiedBadge

/// Meta/Instagram-style verified badge — blue star-edged seal with white checkmark.
/// Uses SF Symbol `checkmark.seal.fill` for the jagged/star edges.
struct VerifiedBadge: View {

    let size: CGFloat

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .blue)
            .accessibilityLabel("Verified")
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

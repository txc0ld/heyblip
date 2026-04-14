import SwiftUI

// MARK: - TypewriterText

/// Character-by-character text reveal animation.
/// Reveals text at ~30ms per character with slight random jitter (+-8ms).
/// Uses Timer for timing. Respects Reduce Motion by showing full text immediately.
struct TypewriterText: View {

    // MARK: - Configuration

    /// The full text to reveal.
    private let text: String

    /// Base delay per character in seconds.
    private let baseDelay: Double

    /// Maximum jitter in seconds applied to each character delay.
    private let jitter: Double

    /// Optional callback fired when the full text has been revealed.
    private let onComplete: (() -> Void)?

    // MARK: - State

    @State private var visibleCount: Int = 0
    @State private var timer: Timer?

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    init(
        _ text: String,
        baseDelay: Double = 0.030,
        jitter: Double = 0.008,
        onComplete: (() -> Void)? = nil
    ) {
        self.text = text
        self.baseDelay = baseDelay
        self.jitter = jitter
        self.onComplete = onComplete
    }

    // MARK: - Body

    var body: some View {
        let displayText: String = {
            if reduceMotion {
                return text
            }
            let endIndex = text.index(text.startIndex, offsetBy: min(visibleCount, text.count))
            return String(text[text.startIndex..<endIndex])
        }()

        Text(displayText)
            .onAppear {
                if reduceMotion {
                    visibleCount = text.count
                    onComplete?()
                } else {
                    startTypewriter()
                }
            }
            .onDisappear {
                cancelTimer()
            }
    }

    // MARK: - Timer Logic

    private func startTypewriter() {
        scheduleNextCharacter()
    }

    private func scheduleNextCharacter() {
        guard visibleCount < text.count else {
            onComplete?()
            return
        }

        let delay = baseDelay + Double.random(in: -jitter...jitter)
        let clampedDelay = max(0.005, delay)

        timer = Timer.scheduledTimer(withTimeInterval: clampedDelay, repeats: false) { _ in
            Task { @MainActor [self] in
                visibleCount += 1
                scheduleNextCharacter()
            }
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Preview

#Preview("Typewriter Text") {
    VStack(alignment: .leading, spacing: 20) {
        TypewriterText("Welcome to HeyBlip. Stay connected at the event.")
            .font(.title3)
            .foregroundStyle(.white)

        TypewriterText("Mesh network active...", baseDelay: 0.05) {
            // Completion
        }
        .font(.caption)
        .foregroundStyle(.gray)
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}

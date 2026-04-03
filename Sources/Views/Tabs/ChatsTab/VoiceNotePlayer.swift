import SwiftUI

// MARK: - VoiceNotePlayer

/// Inline voice note player with waveform visualization, play/pause, duration, and speed toggle.
struct VoiceNotePlayer: View {

    /// Total duration of the voice note in seconds.
    let duration: TimeInterval

    /// Normalized waveform amplitude samples (0.0 - 1.0).
    let waveformSamples: [Float]

    /// Whether this voice note is in an outgoing (from me) bubble.
    let isFromMe: Bool

    /// Opus-encoded audio data for playback. Nil in previews.
    var audioData: Data? = nil

    @State private var isPlaying = false
    @State private var playbackProgress: CGFloat = 0.0
    @State private var playbackSpeed: PlaybackSpeed = .normal
    @State private var playbackTimer: Timer?
    @State private var playerService = AudioService()

    @Environment(\.theme) private var theme

    private enum PlaybackSpeed: Double, CaseIterable {
        case normal = 1.0
        case fast = 1.5
        case faster = 2.0

        var label: String {
            switch self {
            case .normal: return "1x"
            case .fast: return "1.5x"
            case .faster: return "2x"
            }
        }

        var next: PlaybackSpeed {
            switch self {
            case .normal: return .fast
            case .fast: return .faster
            case .faster: return .normal
            }
        }
    }

    var body: some View {
        HStack(spacing: BlipSpacing.sm) {
            // Play/pause button
            playPauseButton

            // Waveform visualization
            waveformView
                .frame(height: 28)

            // Duration / remaining
            durationLabel

            // Speed toggle
            speedToggle
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice note, \(formattedDuration(duration))")
        .accessibilityHint(isPlaying ? "Double tap to pause" : "Double tap to play")
    }

    // MARK: - Play/Pause Button

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
    }

    // MARK: - Waveform

    private var waveformView: some View {
        GeometryReader { geometry in
            let barCount = max(waveformSamples.count, 12)
            let barWidth: CGFloat = 2.5
            let barSpacing: CGFloat = 1.5
            let totalWidth = geometry.size.width
            let barsToShow = min(barCount, Int(totalWidth / (barWidth + barSpacing)))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barsToShow, id: \.self) { index in
                    let amplitude = sampleAmplitude(at: index, total: barsToShow)
                    let barProgress = CGFloat(index) / CGFloat(barsToShow)
                    let isPlayed = barProgress <= playbackProgress

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            isPlayed
                                ? (isFromMe ? Color.white : Color.blipAccentPurple)
                                : (isFromMe ? Color.white.opacity(0.3) : theme.colors.mutedText.opacity(0.3))
                        )
                        .frame(width: barWidth, height: max(4, CGFloat(amplitude) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Duration Label

    private var durationLabel: some View {
        Text(isPlaying ? formattedRemaining : formattedDuration(duration))
            .font(.custom(BlipFontName.medium, size: 11, relativeTo: .caption2))
            .foregroundStyle(foregroundColor.opacity(0.7))
            .monospacedDigit()
            .frame(width: 38, alignment: .trailing)
    }

    // MARK: - Speed Toggle

    private var speedToggle: some View {
        Button {
            playbackSpeed = playbackSpeed.next
        } label: {
            Text(playbackSpeed.label)
                .font(.custom(BlipFontName.bold, size: 10, relativeTo: .caption2))
                .foregroundStyle(foregroundColor.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(foregroundColor.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
    }

    // MARK: - Helpers

    private var foregroundColor: Color {
        isFromMe ? .white : theme.colors.text
    }

    private var formattedRemaining: String {
        let remaining = duration * (1.0 - Double(playbackProgress))
        return formattedDuration(remaining)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func sampleAmplitude(at index: Int, total: Int) -> Float {
        guard !waveformSamples.isEmpty else {
            // Generate synthetic waveform
            let phase = Float(index) / Float(total)
            return 0.3 + 0.5 * abs(sin(phase * .pi * 4))
        }
        let sampleIndex = Int(Float(index) / Float(total) * Float(waveformSamples.count))
        let clampedIndex = max(0, min(sampleIndex, waveformSamples.count - 1))
        return max(0.15, waveformSamples[clampedIndex])
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let data = audioData else {
            DebugLogger.shared.log("AUDIO", "No audio data available for playback", isError: true)
            simulateFallback()
            return
        }

        do {
            try playerService.play(data: data)
            isPlaying = true
            startProgressTimer()
        } catch {
            DebugLogger.shared.log("AUDIO", "Playback failed: \(error)", isError: true)
            simulateFallback()
        }
    }

    private func stopPlayback() {
        playerService.stopPlayback()
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
    }

    private func startProgressTimer() {
        let adjustedDuration = duration / playbackSpeed.rawValue
        guard adjustedDuration > 0 else { return }
        let interval = 0.05 // 20 updates per second
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                let newProgress = playbackProgress + CGFloat(interval / adjustedDuration)
                if newProgress >= 1.0 {
                    playbackProgress = 0
                    isPlaying = false
                    playbackTimer?.invalidate()
                    playbackTimer = nil
                } else {
                    playbackProgress = newProgress
                }
            }
        }
    }

    /// Fallback animation when no audioData is available (previews).
    private func simulateFallback() {
        isPlaying = true
        let adjustedDuration = duration / playbackSpeed.rawValue
        guard adjustedDuration > 0 else { return }
        let interval = 0.05
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                let newProgress = playbackProgress + CGFloat(interval / adjustedDuration)
                if newProgress >= 1.0 {
                    playbackProgress = 0
                    isPlaying = false
                    playbackTimer?.invalidate()
                    playbackTimer = nil
                } else {
                    playbackProgress = newProgress
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Voice Note Player - Outgoing") {
    VStack {
        VoiceNotePlayer(
            duration: 12.5,
            waveformSamples: [0.2, 0.4, 0.6, 0.8, 0.5, 0.3, 0.7, 0.9, 0.4, 0.2, 0.5, 0.6],
            isFromMe: true
        )
        .frame(width: 220)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.blipAccentPurple)
        )
    }
    .padding()
    .background(GradientBackground())
    .environment(\.theme, Theme.shared)
}

#Preview("Voice Note Player - Incoming") {
    VStack {
        VoiceNotePlayer(
            duration: 8.0,
            waveformSamples: [],
            isFromMe: false
        )
        .frame(width: 220)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    .padding()
    .background(GradientBackground())
    .environment(\.theme, Theme.shared)
}

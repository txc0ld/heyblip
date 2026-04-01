import Foundation
import SwiftData
import BlipProtocol
import BlipMesh

// MARK: - PTT State

/// Push-to-talk state machine states.
enum PTTState: Sendable, Equatable {
    /// Idle: button visible, ready to record.
    case idle
    /// Recording: user is holding the button, audio is being captured.
    case recording(duration: TimeInterval)
    /// Encoding: recording stopped, audio is being encoded and prepared for send.
    case encoding
    /// Sending: encoded audio chunks are being transmitted.
    case sending(progress: Double)
    /// Playing: received PTT audio is being played back.
    case playing(from: String, progress: Double)
    /// Error state.
    case error(String)
}

// MARK: - PTT View Model

/// Manages the push-to-talk state machine: idle -> recording -> sending.
///
/// Flow:
/// 1. User presses and holds PTT button -> start recording
/// 2. Audio captured via AudioService -> Opus encoded -> streamed as pttAudio packets
/// 3. User releases button -> stop recording -> send final chunk
/// 4. On receive: decode Opus -> play via AudioService
///
/// Supports both hold-to-talk and toggle-talk modes from UserPreferences.
@MainActor
@Observable
final class PTTViewModel {

    // MARK: - Published State

    /// Current PTT state.
    var state: PTTState = .idle

    /// Current recording duration in seconds.
    var recordingDuration: TimeInterval = 0

    /// Audio level during recording (0.0 to 1.0, for ripple animation).
    var audioLevel: Float = 0

    /// Whether the maximum duration warning has been shown.
    var isNearMaxDuration = false

    /// PTT mode preference (hold-to-talk vs toggle-talk).
    var pttMode: PTTMode = .holdToTalk

    /// The channel this PTT session targets.
    var targetChannel: Channel?

    /// Queue of received PTT audio to play sequentially.
    var playbackQueue: [PTTPlaybackItem] = []

    /// Currently playing item info.
    var nowPlaying: PTTPlaybackItem?

    /// Error message, if any.
    var errorMessage: String?

    /// Maximum recording duration (adjusted by crowd scale).
    var maxDuration: TimeInterval = AudioService.maxVoiceNoteDuration

    // MARK: - Supporting Types

    struct PTTPlaybackItem: Identifiable, Sendable {
        let id: UUID
        let senderName: String
        let audioData: Data
        let duration: TimeInterval
        let receivedAt: Date
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let audioService: AudioService
    private let messageService: MessageService
    private var audioDelegate: PTTAudioDelegate?
    @ObservationIgnored nonisolated(unsafe) private var pttObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Warning threshold: seconds before max duration.
    private static let warningThreshold: TimeInterval = 5.0

    /// Minimum recording duration to send (avoid accidental taps).
    private static let minimumDuration: TimeInterval = 0.3

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        audioService: AudioService,
        messageService: MessageService
    ) {
        self.modelContainer = modelContainer
        self.audioService = audioService
        self.messageService = messageService

        setupAudioDelegate()
        setupPTTReceiver()
    }

    deinit {
        if let obs = pttObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Configuration

    /// Set the target channel for PTT and adjust max duration based on crowd scale.
    func configure(channel: Channel, crowdScale: CrowdScaleDisplay) {
        targetChannel = channel

        switch crowdScale {
        case .gather:
            maxDuration = AudioService.maxVoiceNoteDuration // 30s
        case .festival:
            maxDuration = AudioService.maxVoiceNoteDurationFestival // 15s
        case .mega, .massive:
            maxDuration = 0 // PTT disabled in mega/massive (text-only)
        }
    }

    // MARK: - PTT Actions

    /// Start recording (press/hold).
    func startRecording() {
        guard case .idle = state else { return }
        guard maxDuration > 0 else {
            errorMessage = "Push-to-talk is unavailable at this crowd density"
            return
        }

        do {
            try audioService.startPTTRecording(maxDuration: maxDuration)
            state = .recording(duration: 0)
            recordingDuration = 0
            audioLevel = 0
            isNearMaxDuration = false
        } catch {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Stop recording (release/toggle).
    func stopRecording() {
        guard case .recording = state else { return }

        do {
            let result = try audioService.stopPTTRecording()

            // Check minimum duration
            if result.duration < Self.minimumDuration {
                state = .idle
                recordingDuration = 0
                return
            }

            state = .encoding

            // Send the complete audio
            Task {
                await sendPTTAudio(data: result.data, duration: result.duration)
            }

        } catch {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Cancel recording without sending.
    func cancelRecording() {
        audioService.cancelRecording()
        state = .idle
        recordingDuration = 0
        audioLevel = 0
        isNearMaxDuration = false
    }

    /// Toggle-talk mode: press once to start, press again to stop.
    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        default:
            break
        }
    }

    // MARK: - Playback

    /// Play received PTT audio.
    func playReceivedAudio(_ item: PTTPlaybackItem) {
        nowPlaying = item

        do {
            try audioService.play(data: item.audioData)
            state = .playing(from: item.senderName, progress: 0)
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
            nowPlaying = nil
            state = .idle
        }
    }

    /// Play the next item in the playback queue.
    func playNextInQueue() {
        guard !playbackQueue.isEmpty else {
            nowPlaying = nil
            state = .idle
            return
        }

        let next = playbackQueue.removeFirst()
        playReceivedAudio(next)
    }

    /// Stop playback.
    func stopPlayback() {
        audioService.stopPlayback()
        nowPlaying = nil
        state = .idle
    }

    /// Clear the playback queue.
    func clearQueue() {
        playbackQueue.removeAll()
    }

    // MARK: - Private: Send

    private func sendPTTAudio(data: Data, duration: TimeInterval) async {
        guard let channel = targetChannel else {
            state = .error("No target channel")
            return
        }

        state = .sending(progress: 0)

        do {
            _ = try await messageService.sendVoiceNote(
                audioData: data,
                duration: duration,
                to: channel
            )
            state = .sending(progress: 1.0)

            // Brief delay to show completion, then return to idle
            try? await Task.sleep(for: .milliseconds(300))
            state = .idle
        } catch {
            state = .error("Send failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription

            // Return to idle after showing error
            try? await Task.sleep(for: .seconds(2))
            state = .idle
        }
    }

    // MARK: - Private: Audio Delegate

    private func setupAudioDelegate() {
        let delegate = PTTAudioDelegate { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        } onRecordChunk: { [weak self] data, duration in
            Task { @MainActor in
                self?.recordingDuration = duration
                self?.state = .recording(duration: duration)

                // Check warning threshold
                if let maxDur = self?.maxDuration, duration >= (maxDur - Self.warningThreshold) {
                    self?.isNearMaxDuration = true
                }
            }
        } onFinishPlayback: { [weak self] success in
            Task { @MainActor in
                self?.nowPlaying = nil
                self?.playNextInQueue()
            }
        } onPlaybackProgress: { [weak self] progress in
            Task { @MainActor in
                if let sender = self?.nowPlaying?.senderName {
                    self?.state = .playing(from: sender, progress: progress)
                }
            }
        }

        self.audioDelegate = delegate
        audioService.delegate = delegate
    }

    // MARK: - Private: PTT Receiver

    private func setupPTTReceiver() {
        pttObservation = NotificationCenter.default.addObserver(
            forName: .didReceivePTTAudio,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let packet = notification.userInfo?["packet"] as? Packet else { return }

            Task { @MainActor in
                self?.handleReceivedPTT(packet)
            }
        }
    }

    private func handleReceivedPTT(_ packet: Packet) {
        let audioData = packet.payload

        // Resolve sender name from peer
        let senderName = "Peer \(packet.senderID.description.prefix(8))"

        let item = PTTPlaybackItem(
            id: UUID(),
            senderName: senderName,
            audioData: audioData,
            duration: 0, // Duration determined on playback
            receivedAt: packet.date
        )

        // If nothing is playing, start immediately
        if case .idle = state {
            playReceivedAudio(item)
        } else {
            playbackQueue.append(item)
        }
    }

    // MARK: - Reset

    /// Reset all PTT state.
    func reset() {
        if audioService.isRecording {
            audioService.cancelRecording()
        }
        if audioService.isPlaying {
            audioService.stopPlayback()
        }
        state = .idle
        recordingDuration = 0
        audioLevel = 0
        isNearMaxDuration = false
        nowPlaying = nil
        playbackQueue.removeAll()
        errorMessage = nil
    }
}

// MARK: - PTT Audio Delegate (Bridge)

/// Bridges AudioServiceDelegate callbacks to closures for the view model.
private final class PTTAudioDelegate: AudioServiceDelegate, @unchecked Sendable {

    private let onLevel: (Float) -> Void
    private let onChunk: (Data, TimeInterval) -> Void
    private let onFinish: (Bool) -> Void
    private let onProgress: (Double) -> Void

    init(
        onLevel: @escaping (Float) -> Void,
        onRecordChunk: @escaping (Data, TimeInterval) -> Void,
        onFinishPlayback: @escaping (Bool) -> Void,
        onPlaybackProgress: @escaping (Double) -> Void
    ) {
        self.onLevel = onLevel
        self.onChunk = onRecordChunk
        self.onFinish = onFinishPlayback
        self.onProgress = onPlaybackProgress
    }

    func audioService(_ service: AudioService, didRecordChunk data: Data, duration: TimeInterval) {
        onChunk(data, duration)
    }

    func audioService(_ service: AudioService, didFinishRecording data: Data, duration: TimeInterval) {
        // Handled by the view model directly via stopPTTRecording
    }

    func audioService(_ service: AudioService, didFinishPlayback successfully: Bool) {
        onFinish(successfully)
    }

    func audioService(_ service: AudioService, didUpdateRecordingLevel level: Float) {
        onLevel(level)
    }

    func audioService(_ service: AudioService, didUpdatePlaybackProgress progress: Double) {
        onProgress(progress)
    }

    func audioService(_ service: AudioService, didFailWithError error: AudioServiceError) {
        // Errors surface via the view model's state
    }
}

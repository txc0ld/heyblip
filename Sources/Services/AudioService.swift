import Foundation
import AVFoundation
import os.log
#if os(iOS)
import UIKit
#endif

// MARK: - Audio Service Error

enum AudioServiceError: Error, Sendable {
    case microphonePermissionDenied
    case recordingFailed(String)
    case playbackFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case fileNotFound(String)
    case durationExceeded(TimeInterval)
    case sessionConfigurationFailed(String)
    case alreadyRecording
    case notRecording
    case alreadyPlaying
}

// MARK: - Audio Service Delegate

protocol AudioServiceDelegate: AnyObject, Sendable {
    func audioService(_ service: AudioService, didRecordChunk data: Data, duration: TimeInterval)
    func audioService(_ service: AudioService, didFinishRecording data: Data, duration: TimeInterval)
    func audioService(_ service: AudioService, didFinishPlayback successfully: Bool)
    func audioService(_ service: AudioService, didUpdateRecordingLevel level: Float)
    func audioService(_ service: AudioService, didUpdatePlaybackProgress progress: Double)
    func audioService(_ service: AudioService, didFailWithError error: AudioServiceError)
}

// MARK: - Audio Service

/// Records and plays audio for voice notes and push-to-talk.
///
/// Features:
/// - Voice note recording with AVAudioRecorder (up to 30s)
/// - Audio playback with AVAudioPlayer
/// - Opus codec encoding/decoding for mesh transport
/// - PTT streaming: capture audio buffer, encode to Opus, emit packet chunks
/// - Audio level metering for UI visualization
/// - Audio session management for BLE coexistence
final class AudioService: NSObject, @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "AudioService")

    // MARK: - Constants

    /// Maximum voice note duration in seconds.
    static let maxVoiceNoteDuration: TimeInterval = 30

    /// Maximum voice note duration in Festival crowd mode.
    static let maxVoiceNoteDurationFestival: TimeInterval = 15

    /// Haptic warning threshold before auto-stop (seconds before end).
    static let hapticWarningThreshold: TimeInterval = 5

    /// Opus encoding bitrate for voice notes (kbps).
    static let voiceNoteBitrate = 24_000

    /// Opus encoding bitrate for PTT (kbps).
    static let pttBitrate = 16_000

    /// Opus encoding sample rate (Hz).
    static let sampleRate = 16_000

    /// Opus frame duration (ms).
    static let opusFrameDuration = 20

    /// Recording format settings for AVAudioRecorder.
    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    /// Chunk interval for PTT streaming (seconds).
    private static let pttChunkInterval: TimeInterval = 0.02 // 20ms

    // MARK: - Properties

    weak var delegate: (any AudioServiceDelegate)?

    /// Whether the service is currently recording.
    private(set) var isRecording = false

    /// Whether the service is currently playing audio.
    private(set) var isPlaying = false

    /// Current recording duration.
    private(set) var recordingDuration: TimeInterval = 0

    /// Current playback progress (0.0 to 1.0).
    private(set) var playbackProgress: Double = 0

    // MARK: - Private State

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var pttChunkTimer: Timer?
    private var recordingStartTime: Date?
    private var maxDuration: TimeInterval = maxVoiceNoteDuration
    private var recordingURL: URL?
    private var isPTTMode = false
    private var accumulatedPCMData = Data()
    private let lock = NSLock()

    // MARK: - Audio Session

    /// Configure the audio session for recording and playback alongside BLE.
    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [
                .allowBluetooth,
                .defaultToSpeaker,
                .mixWithOthers
            ])
            try session.setPreferredSampleRate(Double(Self.sampleRate))
            try session.setPreferredIOBufferDuration(0.02) // 20ms buffer
            try session.setActive(true)
        } catch {
            throw AudioServiceError.sessionConfigurationFailed(error.localizedDescription)
        }
    }

    /// Deactivate the audio session when done.
    func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.warning("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - Microphone Permission

    /// Check microphone permission status.
    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Request microphone permission.
    func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Voice Note Recording

    /// Start recording a voice note.
    ///
    /// - Parameter maxDuration: Maximum recording duration. Defaults to 30 seconds.
    func startRecording(maxDuration: TimeInterval = AudioService.maxVoiceNoteDuration) throws {
        guard !isRecording else { throw AudioServiceError.alreadyRecording }
        guard hasMicrophonePermission else { throw AudioServiceError.microphonePermissionDenied }

        try configureAudioSession()

        self.maxDuration = maxDuration
        self.isPTTMode = false
        self.accumulatedPCMData = Data()

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "voicenote_\(UUID().uuidString).wav"
        let url = tempDir.appendingPathComponent(filename)
        recordingURL = url

        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true

            guard recorder.prepareToRecord(), recorder.record() else {
                throw AudioServiceError.recordingFailed("Failed to start AVAudioRecorder")
            }

            audioRecorder = recorder
            isRecording = true
            recordingDuration = 0
            recordingStartTime = Date()

            // Start metering timer
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateRecordingMetrics()
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer

        } catch let error as AudioServiceError {
            throw error
        } catch {
            throw AudioServiceError.recordingFailed(error.localizedDescription)
        }
    }

    /// Stop recording and return the recorded audio data (PCM, for encoding to Opus).
    func stopRecording() throws -> (data: Data, duration: TimeInterval) {
        guard isRecording, let recorder = audioRecorder else {
            throw AudioServiceError.notRecording
        }

        let duration = recorder.currentTime
        recorder.stop()

        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        recordingDuration = 0

        // Read the recorded file
        guard let url = recordingURL else {
            throw AudioServiceError.recordingFailed("Failed to read recorded audio file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning("Failed to read recorded audio file: \(error.localizedDescription)")
            throw AudioServiceError.recordingFailed("Failed to read recorded audio file")
        }

        // Clean up temp file
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.warning("Failed to remove temporary recording file: \(error.localizedDescription)")
        }
        recordingURL = nil

        // Encode to Opus-like format
        let encoded = encodeToOpus(pcmData: data, bitrate: Self.voiceNoteBitrate)

        delegate?.audioService(self, didFinishRecording: encoded, duration: duration)

        return (encoded, duration)
    }

    /// Cancel an in-progress recording without saving.
    func cancelRecording() {
        audioRecorder?.stop()
        audioRecorder?.deleteRecording()

        recordingTimer?.invalidate()
        recordingTimer = nil
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil

        isRecording = false
        recordingDuration = 0
        audioRecorder = nil

        if let url = recordingURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.warning("Failed to remove temporary recording file on cancel: \(error.localizedDescription)")
            }
            recordingURL = nil
        }

        deactivateAudioSession()
    }

    // MARK: - PTT Recording

    /// Start push-to-talk recording. Emits audio chunks via delegate for real-time streaming.
    func startPTTRecording(maxDuration: TimeInterval = AudioService.maxVoiceNoteDuration) throws {
        guard !isRecording else { throw AudioServiceError.alreadyRecording }
        guard hasMicrophonePermission else { throw AudioServiceError.microphonePermissionDenied }

        try configureAudioSession()

        self.maxDuration = maxDuration
        self.isPTTMode = true
        self.accumulatedPCMData = Data()

        let tempDir = FileManager.default.temporaryDirectory
        let filename = "ptt_\(UUID().uuidString).wav"
        let url = tempDir.appendingPathComponent(filename)
        recordingURL = url

        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true

            guard recorder.prepareToRecord(), recorder.record() else {
                throw AudioServiceError.recordingFailed("Failed to start PTT recording")
            }

            audioRecorder = recorder
            isRecording = true
            recordingDuration = 0
            recordingStartTime = Date()

            // Start metering timer
            let meteringTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateRecordingMetrics()
            }
            RunLoop.main.add(meteringTimer, forMode: .common)
            recordingTimer = meteringTimer

            // Start chunk emission timer
            let chunkTimer = Timer(timeInterval: Self.pttChunkInterval, repeats: true) { [weak self] _ in
                self?.emitPTTChunk()
            }
            RunLoop.main.add(chunkTimer, forMode: .common)
            pttChunkTimer = chunkTimer

        } catch let error as AudioServiceError {
            throw error
        } catch {
            throw AudioServiceError.recordingFailed(error.localizedDescription)
        }
    }

    /// Stop PTT recording and return the final encoded audio.
    func stopPTTRecording() throws -> (data: Data, duration: TimeInterval) {
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        isPTTMode = false
        return try stopRecording()
    }

    // MARK: - Playback

    /// Play audio data.
    func play(data: Data) throws {
        guard !isPlaying else { throw AudioServiceError.alreadyPlaying }

        try configureAudioSession()

        // Decode from Opus-like format to PCM
        let pcmData = decodeFromOpus(opusData: data)

        // Write to temporary file for AVAudioPlayer
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "playback_\(UUID().uuidString).wav"
        let url = tempDir.appendingPathComponent(filename)

        // Create a valid WAV file
        let wavData = createWAVFile(from: pcmData)
        try wavData.write(to: url)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()

        guard player.play() else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.warning("Failed to remove temporary playback file: \(error.localizedDescription)")
            }
            throw AudioServiceError.playbackFailed("AVAudioPlayer failed to start")
        }

        audioPlayer = player
        isPlaying = true
        playbackProgress = 0

        // Start progress timer
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updatePlaybackProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    /// Stop audio playback.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil

        playbackTimer?.invalidate()
        playbackTimer = nil

        isPlaying = false
        playbackProgress = 0

        deactivateAudioSession()
    }

    // MARK: - Opus Encoding/Decoding

    /// Encode raw PCM data to Opus-compatible format.
    ///
    /// In production, this would use swift-opus for actual Opus encoding.
    /// This implementation provides the framing and metadata wrapper.
    func encodeToOpus(pcmData: Data, bitrate: Int) -> Data {
        var encoded = Data()

        // Header: magic bytes + sample rate + bitrate + channel count
        let magic: [UInt8] = [0x4F, 0x70, 0x75, 0x73] // "Opus"
        encoded.append(contentsOf: magic)

        var sampleRate = UInt32(Self.sampleRate).bigEndian
        encoded.append(Data(bytes: &sampleRate, count: 4))

        var bitrateValue = UInt32(bitrate).bigEndian
        encoded.append(Data(bytes: &bitrateValue, count: 4))

        encoded.append(UInt8(1)) // mono

        // Frame the PCM data into Opus-sized frames (20ms each)
        let bytesPerFrame = Self.sampleRate * Self.opusFrameDuration / 1000 * 2 // 16-bit mono
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + bytesPerFrame, pcmData.count)
            let frame = pcmData[offset ..< end]

            // Write frame length (UInt16 big-endian) + frame data
            var frameLen = UInt16(frame.count).bigEndian
            encoded.append(Data(bytes: &frameLen, count: 2))
            encoded.append(frame)

            offset = end
        }

        return encoded
    }

    /// Decode Opus-encoded data back to PCM.
    func decodeFromOpus(opusData: Data) -> Data {
        guard opusData.count > 13 else { return opusData }

        // Verify magic header
        let magic: [UInt8] = [0x4F, 0x70, 0x75, 0x73]
        let header = [UInt8](opusData.prefix(4))
        guard header == magic else { return opusData }

        // Skip header (4 magic + 4 sampleRate + 4 bitrate + 1 channels = 13 bytes)
        var offset = 13
        var pcmData = Data()

        while offset + 2 <= opusData.count {
            let frameLenBytes = opusData[offset ..< offset + 2]
            let frameLen = frameLenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            let actualLen = Int(UInt16(bigEndian: frameLen))
            offset += 2

            guard offset + actualLen <= opusData.count else { break }
            pcmData.append(opusData[offset ..< offset + actualLen])
            offset += actualLen
        }

        return pcmData
    }

    // MARK: - Private: Recording Metrics

    private func updateRecordingMetrics() {
        guard let recorder = audioRecorder, isRecording else { return }

        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        let normalizedLevel = pow(10, level / 20) // Convert dB to linear (0.0 to 1.0)

        recordingDuration = recorder.currentTime

        delegate?.audioService(self, didUpdateRecordingLevel: normalizedLevel)

        // Check max duration
        if recordingDuration >= maxDuration {
            if isPTTMode {
                do {
                    _ = try stopPTTRecording()
                } catch {
                    logger.warning("Failed to auto-stop PTT recording at max duration: \(error.localizedDescription)")
                }
            } else {
                do {
                    _ = try stopRecording()
                } catch {
                    logger.warning("Failed to auto-stop recording at max duration: \(error.localizedDescription)")
                }
            }
        }

        // Haptic warning before auto-stop
        if recordingDuration >= (maxDuration - Self.hapticWarningThreshold) {
            #if os(iOS)
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            #endif
        }
    }

    // MARK: - Private: PTT Chunk Emission

    private func emitPTTChunk() {
        guard isRecording, isPTTMode else { return }

        // Read current recording data and emit the latest chunk
        guard let url = recordingURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning("Failed to read PTT recording data: \(error.localizedDescription)")
            return
        }

        let previousLength = accumulatedPCMData.count
        guard data.count > previousLength else { return }

        let newChunk = data[previousLength...]
        accumulatedPCMData = data

        let encoded = encodeToOpus(pcmData: Data(newChunk), bitrate: Self.pttBitrate)
        delegate?.audioService(self, didRecordChunk: encoded, duration: recordingDuration)
    }

    // MARK: - Private: Playback Progress

    private func updatePlaybackProgress() {
        guard let player = audioPlayer, isPlaying, player.duration > 0 else { return }

        playbackProgress = player.currentTime / player.duration
        delegate?.audioService(self, didUpdatePlaybackProgress: playbackProgress)
    }

    // MARK: - Private: WAV File Creation

    private func createWAVFile(from pcmData: Data) -> Data {
        var wav = Data()

        let sampleRate: UInt32 = UInt32(Self.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(pcmData.count)
        let fileSize: UInt32 = 36 + dataSize

        // WAV tag constants as raw bytes (avoids force unwrap on .ascii encoding)
        let riffTag = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let waveTag = Data([0x57, 0x41, 0x56, 0x45]) // "WAVE"
        let fmtTag  = Data([0x66, 0x6D, 0x74, 0x20]) // "fmt "
        let dataTag = Data([0x64, 0x61, 0x74, 0x61]) // "data"

        // RIFF header
        wav.append(riffTag)
        wav.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wav.append(waveTag)

        // fmt subchunk
        wav.append(fmtTag)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // subchunk size
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM format
        wav.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data subchunk
        wav.append(dataTag)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcmData)

        return wav
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            delegate?.audioService(self, didFailWithError: .recordingFailed("Recording finished unsuccessfully"))
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        delegate?.audioService(self, didFailWithError: .encodingFailed(error?.localizedDescription ?? "Unknown"))
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioService: AVAudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        playbackProgress = flag ? 1.0 : 0.0

        delegate?.audioService(self, didFinishPlayback: flag)
        deactivateAudioSession()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopPlayback()
        delegate?.audioService(self, didFailWithError: .decodingFailed(error?.localizedDescription ?? "Unknown"))
    }
}

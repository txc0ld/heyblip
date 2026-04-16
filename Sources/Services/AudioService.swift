import Foundation
import AVFoundation
import Darwin
import Opus
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

    /// Maximum voice note duration in Event crowd mode.
    static let maxVoiceNoteDurationEvent: TimeInterval = 15

    /// Haptic warning threshold before auto-stop (seconds before end).
    static let hapticWarningThreshold: TimeInterval = 5

    /// Opus encoding bitrate for voice notes (kbps).
    static let voiceNoteBitrate = 24_000

    /// Opus encoding bitrate for PTT (kbps).
    static let pttBitrate = 16_000

    /// Opus encoding sample rate (Hz).
    static let sampleRate = 16_000

    /// Opus encoding channels.
    static let channelCount = 1

    /// Opus frame duration (ms).
    static let opusFrameDuration = 20

    /// Samples per Opus frame (20 ms).
    static let opusFrameSampleCount = sampleRate * opusFrameDuration / 1000

    /// Bytes per PCM sample.
    static let pcmBytesPerSample = MemoryLayout<Int16>.size

    /// Bytes per PCM Opus frame.
    static let pcmBytesPerFrame = opusFrameSampleCount * channelCount * pcmBytesPerSample

    /// Maximum packet size for a single Opus frame.
    static let maximumOpusPacketSize = 1275

    /// Custom container magic for versioned Opus payloads.
    static let opusContainerMagic: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64] // "OpusHead"

    /// Legacy custom container magic for raw PCM frame payloads.
    static let legacyOpusContainerMagic: [UInt8] = [0x4F, 0x70, 0x75, 0x73] // "Opus"

    /// Current version of the custom Opus container.
    static let opusContainerVersion: UInt8 = 1

    /// Swift cannot call the variadic `opus_encoder_ctl` API directly, so resolve a fixed-signature thunk.
    private typealias OpusEncoderControlFunction = @convention(c) (OpaquePointer?, Int32, Int32) -> Int32

    private static let opusEncoderControl: OpusEncoderControlFunction? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let symbol = dlsym(handle, "opus_encoder_ctl") else {
            return nil
        }

        return unsafeBitCast(symbol, to: OpusEncoderControlFunction.self)
    }()

    /// Recording format settings for AVAudioRecorder.
    nonisolated(unsafe) private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channelCount,
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
    private var pendingPTTPCMData = Data()
    private let lock = NSLock()

    private var systemObservers: [NSObjectProtocol] = []
    private var didConfigureObservers = false

    // MARK: - System Lifecycle Observers

    /// Subscribe to the system events that can corrupt or strand a recording session:
    /// phone call interruptions, headphone unplugs, and app backgrounding. Called lazily
    /// on the first session configuration so unit tests can construct an AudioService
    /// without fighting AVAudioSession.
    private func installSystemObservers() {
        guard !didConfigureObservers else { return }
        didConfigureObservers = true

        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }

        #if os(iOS)
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleEnteredBackground()
        }
        systemObservers = [interruption, routeChange, background]
        #else
        systemObservers = [interruption, routeChange]
        #endif
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        switch type {
        case .began:
            // Phone call / Siri / alarm grabbed the session. Discard the in-flight
            // recording — half a voice note isn't worth keeping — and stop playback.
            if isRecording {
                cancelRecording()
                delegate?.audioService(self, didFailWithError: .recordingFailed("Recording interrupted"))
            }
            if isPlaying {
                stopPlayback()
            }
        case .ended:
            // Only resume playback if the system explicitly tells us we should.
            // Mid-recording resumption is intentionally NOT supported — partial
            // resumption would produce a Frankenstein clip.
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume), let player = audioPlayer, !player.isPlaying {
                    player.play()
                    isPlaying = true
                }
            }
        @unknown default:
            return
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }

        // Headphones (or any output route) disappeared — pause so audio doesn't
        // suddenly blast through the speaker. The user can hit play again.
        if reason == .oldDeviceUnavailable, isPlaying {
            stopPlayback()
        }
    }

    private func handleEnteredBackground() {
        // Recording in the background isn't part of the product yet — and leaving
        // an active recording running drains battery + holds the mic. Cancel cleanly
        // so the next foreground session starts from a known state.
        if isRecording {
            cancelRecording()
            delegate?.audioService(self, didFailWithError: .recordingFailed("Recording cancelled by app backgrounding"))
        }
    }

    // MARK: - Audio Session

    /// Configure the audio session for recording and playback alongside BLE.
    func configureAudioSession() throws {
        installSystemObservers()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [
                .allowBluetoothA2DP,
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
        // The lock guards the small "is anything live?" decision and tears down any
        // stale timer left over from a racy cancel-then-start sequence. Without this
        // a second `startRecording` call could observe `isRecording == false` while a
        // background timer block was still firing into the previous session.
        lock.lock()
        guard !isRecording else {
            lock.unlock()
            throw AudioServiceError.alreadyRecording
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        lock.unlock()

        guard hasMicrophonePermission else { throw AudioServiceError.microphonePermissionDenied }

        try configureAudioSession()

        self.maxDuration = maxDuration
        self.isPTTMode = false
        self.accumulatedPCMData = Data()
        self.pendingPTTPCMData = Data()

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

        let pcmData = extractPCMData(fromRecordedFileData: data)
        let encoded = try encodeToOpus(pcmData: pcmData, bitrate: Self.voiceNoteBitrate)

        delegate?.audioService(self, didFinishRecording: encoded, duration: duration)

        return (encoded, duration)
    }

    /// Cancel an in-progress recording without saving.
    func cancelRecording() {
        lock.lock()
        let recorderToStop = audioRecorder
        audioRecorder = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        pttChunkTimer?.invalidate()
        pttChunkTimer = nil
        isRecording = false
        recordingDuration = 0
        accumulatedPCMData = Data()
        pendingPTTPCMData = Data()
        let urlToRemove = recordingURL
        recordingURL = nil
        lock.unlock()

        recorderToStop?.stop()
        recorderToStop?.deleteRecording()

        if let urlToRemove {
            do {
                try FileManager.default.removeItem(at: urlToRemove)
            } catch {
                logger.warning("Failed to remove temporary recording file on cancel: \(error.localizedDescription)")
            }
        }

        deactivateAudioSession()
    }

    deinit {
        for observer in systemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        recordingTimer?.invalidate()
        playbackTimer?.invalidate()
        pttChunkTimer?.invalidate()
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
        self.pendingPTTPCMData = Data()

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
        emitPTTChunk(flushFinalChunk: true)
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

        let pcmData = try decodeFromOpus(opusData: data)

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

    /// Encode raw PCM data to Opus using 20 ms frames inside Blip's custom container.
    private func encodeToOpus(pcmData: Data, bitrate: Int) throws -> Data {
        let normalizedPCMData = normalizePCMByteAlignment(pcmData)
        let (encoded, _) = try encodePCMFramesAsOpus(
            normalizedPCMData,
            bitrate: bitrate,
            padFinalFrame: true
        )

        guard !encoded.isEmpty else {
            throw AudioServiceError.encodingFailed("No PCM frames were available for Opus encoding")
        }

        return encoded
    }

    /// Decode Blip Opus payloads back to raw PCM, preserving support for legacy PCM-framed notes.
    private func decodeFromOpus(opusData: Data) throws -> Data {
        if starts(with: Self.opusContainerMagic, in: opusData) {
            guard opusData.count >= 18 else {
                throw AudioServiceError.decodingFailed("Opus payload header is truncated")
            }

            let version = opusData[Self.opusContainerMagic.count]
            guard version == Self.opusContainerVersion else {
                throw AudioServiceError.decodingFailed("Unsupported Opus payload version: \(version)")
            }

            guard
                let sampleRate = readUInt32BigEndian(from: opusData, at: 9),
                let channels = opusData[safe: 17]
            else {
                throw AudioServiceError.decodingFailed("Opus payload header is invalid")
            }

            return try decodeOpusFrames(
                from: opusData,
                headerLength: 18,
                sampleRate: Int(sampleRate),
                channels: Int(channels)
            )
        }

        if starts(with: Self.legacyOpusContainerMagic, in: opusData) {
            return decodeLegacyPCMFrames(from: opusData, headerLength: 13)
        }

        return opusData
    }

    // MARK: - Private: Opus Helpers

    private func encodePCMFramesAsOpus(
        _ pcmData: Data,
        bitrate: Int,
        padFinalFrame: Bool
    ) throws -> (encoded: Data, remainder: Data) {
        let completeFrameByteCount = (pcmData.count / Self.pcmBytesPerFrame) * Self.pcmBytesPerFrame
        var remainder = Data(pcmData.dropFirst(completeFrameByteCount))
        var framesToEncode = [Data]()

        if completeFrameByteCount > 0 {
            var offset = 0
            while offset < completeFrameByteCount {
                let end = offset + Self.pcmBytesPerFrame
                framesToEncode.append(Data(pcmData[offset..<end]))
                offset = end
            }
        }

        if padFinalFrame, !remainder.isEmpty {
            var paddedFrame = normalizePCMByteAlignment(remainder)
            guard paddedFrame.count <= Self.pcmBytesPerFrame else {
                throw AudioServiceError.encodingFailed("PCM remainder exceeded single Opus frame size")
            }
            paddedFrame.append(Data(repeating: 0, count: Self.pcmBytesPerFrame - paddedFrame.count))
            framesToEncode.append(paddedFrame)
            remainder = Data()
        }

        guard !framesToEncode.isEmpty else {
            return (Data(), remainder)
        }

        let encoder = try createOpusEncoder(bitrate: bitrate)
        defer { opus_encoder_destroy(encoder) }

        var encoded = makeOpusContainerHeader(bitrate: bitrate)
        for frame in framesToEncode {
            let packet = try encodePCMFrame(frame, with: encoder)
            guard packet.count <= Int(UInt16.max) else {
                throw AudioServiceError.encodingFailed("Opus packet exceeded container frame limit")
            }

            var frameLength = UInt16(packet.count).bigEndian
            encoded.append(withUnsafeBytes(of: &frameLength) { Data($0) })
            encoded.append(packet)
        }

        return (encoded, remainder)
    }

    private func encodePCMFrame(_ frame: Data, with encoder: OpaquePointer) throws -> Data {
        guard frame.count == Self.pcmBytesPerFrame else {
            throw AudioServiceError.encodingFailed("PCM frame size \(frame.count) does not match expected \(Self.pcmBytesPerFrame)")
        }

        var output = [UInt8](repeating: 0, count: Self.maximumOpusPacketSize)
        let encodedLength = try frame.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw AudioServiceError.encodingFailed("PCM frame buffer is empty")
            }

            let samples = baseAddress.assumingMemoryBound(to: Int16.self)
            return try output.withUnsafeMutableBufferPointer { outputBuffer -> Int in
                guard let outputBaseAddress = outputBuffer.baseAddress else {
                    throw AudioServiceError.encodingFailed("Opus output buffer is empty")
                }

                let encodedBytes = opus_encode(
                    encoder,
                    samples,
                    Int32(Self.opusFrameSampleCount),
                    outputBaseAddress,
                    Int32(outputBuffer.count)
                )
                guard encodedBytes >= 0 else {
                    throw AudioServiceError.encodingFailed("Opus encode failed: \(encodedBytes)")
                }

                return Int(encodedBytes)
            }
        }

        return Data(output.prefix(encodedLength))
    }

    private func decodeOpusFrames(
        from opusData: Data,
        headerLength: Int,
        sampleRate: Int,
        channels: Int
    ) throws -> Data {
        let frameSampleCount = sampleRate * Self.opusFrameDuration / 1000
        guard frameSampleCount > 0, channels == Self.channelCount else {
            throw AudioServiceError.decodingFailed("Unsupported Opus audio format: \(sampleRate) Hz, \(channels) channel(s)")
        }

        let decoder = try createOpusDecoder(sampleRate: sampleRate, channels: channels)
        defer { opus_decoder_destroy(decoder) }

        var offset = headerLength
        var pcmData = Data()
        while offset + 2 <= opusData.count {
            guard let frameLength = readUInt16BigEndian(from: opusData, at: offset) else {
                throw AudioServiceError.decodingFailed("Opus frame length is truncated")
            }

            offset += 2
            let frameLengthValue = Int(frameLength)
            guard frameLengthValue > 0, offset + frameLengthValue <= opusData.count else {
                throw AudioServiceError.decodingFailed("Opus frame payload is truncated")
            }

            let frame = Data(opusData[offset..<offset + frameLengthValue])
            pcmData.append(try decodeOpusFrame(frame, with: decoder, frameSampleCount: frameSampleCount, channels: channels))
            offset += frameLengthValue
        }

        return pcmData
    }

    private func decodeOpusFrame(
        _ frame: Data,
        with decoder: OpaquePointer,
        frameSampleCount: Int,
        channels: Int
    ) throws -> Data {
        var decodedSamples = [Int16](repeating: 0, count: frameSampleCount * channels)
        let decodedFrameCount = try frame.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw AudioServiceError.decodingFailed("Opus frame buffer is empty")
            }

            let input = baseAddress.assumingMemoryBound(to: UInt8.self)
            return try decodedSamples.withUnsafeMutableBufferPointer { outputBuffer -> Int in
                guard let outputBaseAddress = outputBuffer.baseAddress else {
                    throw AudioServiceError.decodingFailed("PCM output buffer is empty")
                }

                let decodedCount = opus_decode(
                    decoder,
                    input,
                    Int32(frame.count),
                    outputBaseAddress,
                    Int32(frameSampleCount),
                    0
                )
                guard decodedCount >= 0 else {
                    throw AudioServiceError.decodingFailed("Opus decode failed: \(decodedCount)")
                }

                return Int(decodedCount)
            }
        }

        let sampleCount = decodedFrameCount * channels
        var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for sample in decodedSamples.prefix(sampleCount) {
            var littleEndianSample = sample.littleEndian
            pcmData.append(withUnsafeBytes(of: &littleEndianSample) { Data($0) })
        }
        return pcmData
    }

    private func decodeLegacyPCMFrames(from opusData: Data, headerLength: Int) -> Data {
        var offset = headerLength
        var pcmData = Data()

        while offset + 2 <= opusData.count {
            guard let frameLength = readUInt16BigEndian(from: opusData, at: offset) else { break }

            offset += 2
            let frameLengthValue = Int(frameLength)
            guard frameLengthValue > 0, offset + frameLengthValue <= opusData.count else { break }

            pcmData.append(opusData[offset..<offset + frameLengthValue])
            offset += frameLengthValue
        }

        return pcmData
    }

    private func createOpusEncoder(bitrate: Int) throws -> OpaquePointer {
        var creationError: Int32 = 0
        guard let encoder = opus_encoder_create(
            Int32(Self.sampleRate),
            Int32(Self.channelCount),
            Opus.Application.voip.rawValue,
            &creationError
        ) else {
            throw AudioServiceError.encodingFailed("Failed to create Opus encoder: \(creationError)")
        }

        guard creationError == Opus.Error.ok.rawValue else {
            opus_encoder_destroy(encoder)
            throw AudioServiceError.encodingFailed("Failed to create Opus encoder: \(creationError)")
        }

        guard let encoderControl = Self.opusEncoderControl else {
            opus_encoder_destroy(encoder)
            throw AudioServiceError.encodingFailed("Failed to resolve Opus bitrate control function")
        }

        let bitrateStatus = encoderControl(encoder, OPUS_SET_BITRATE_REQUEST, Int32(bitrate))
        guard bitrateStatus == Opus.Error.ok.rawValue else {
            opus_encoder_destroy(encoder)
            throw AudioServiceError.encodingFailed("Failed to set Opus bitrate: \(bitrateStatus)")
        }

        return encoder
    }

    private func createOpusDecoder(sampleRate: Int, channels: Int) throws -> OpaquePointer {
        var creationError: Int32 = 0
        guard let decoder = opus_decoder_create(
            Int32(sampleRate),
            Int32(channels),
            &creationError
        ) else {
            throw AudioServiceError.decodingFailed("Failed to create Opus decoder: \(creationError)")
        }

        guard creationError == Opus.Error.ok.rawValue else {
            opus_decoder_destroy(decoder)
            throw AudioServiceError.decodingFailed("Failed to create Opus decoder: \(creationError)")
        }

        return decoder
    }

    private func makeOpusContainerHeader(bitrate: Int) -> Data {
        var header = Data(Self.opusContainerMagic)
        header.append(Self.opusContainerVersion)

        var sampleRate = UInt32(Self.sampleRate).bigEndian
        header.append(withUnsafeBytes(of: &sampleRate) { Data($0) })

        var bitrateValue = UInt32(bitrate).bigEndian
        header.append(withUnsafeBytes(of: &bitrateValue) { Data($0) })

        header.append(UInt8(Self.channelCount))
        return header
    }

    private func extractPCMData(fromRecordedFileData data: Data) -> Data {
        let riffMagic: [UInt8] = [0x52, 0x49, 0x46, 0x46] // "RIFF"
        let waveMagic: [UInt8] = [0x57, 0x41, 0x56, 0x45] // "WAVE"
        let dataMagic: [UInt8] = [0x64, 0x61, 0x74, 0x61] // "data"

        guard starts(with: riffMagic, in: data), data.count >= 12 else {
            return data
        }

        let waveRange = 8..<12
        guard starts(with: waveMagic, in: Data(data[waveRange])) else {
            return data
        }

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = Array(data[offset..<offset + 4])
            guard let chunkSize = readUInt32LittleEndian(from: data, at: offset + 4) else {
                break
            }

            offset += 8
            let chunkSizeValue = Int(chunkSize)
            guard offset + chunkSizeValue <= data.count else {
                break
            }

            if chunkID == dataMagic {
                return Data(data[offset..<offset + chunkSizeValue])
            }

            offset += chunkSizeValue
            if chunkSizeValue % 2 == 1 {
                offset += 1
            }
        }

        return data
    }

    private func normalizePCMByteAlignment(_ pcmData: Data) -> Data {
        guard !pcmData.isEmpty, !pcmData.count.isMultiple(of: Self.pcmBytesPerSample) else {
            return pcmData
        }

        var aligned = pcmData
        aligned.append(0)
        return aligned
    }

    private func starts(with prefix: [UInt8], in data: Data) -> Bool {
        guard data.count >= prefix.count else { return false }
        return Array(data.prefix(prefix.count)) == prefix
    }

    private func readUInt16BigEndian(from data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let upper = UInt16(data[offset]) << 8
        let lower = UInt16(data[offset + 1])
        return upper | lower
    }

    private func readUInt32BigEndian(from data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let byte0 = UInt32(data[offset]) << 24
        let byte1 = UInt32(data[offset + 1]) << 16
        let byte2 = UInt32(data[offset + 2]) << 8
        let byte3 = UInt32(data[offset + 3])
        return byte0 | byte1 | byte2 | byte3
    }

    private func readUInt32LittleEndian(from data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
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
            Task { @MainActor in
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
            }
            #endif
        }
    }

    // MARK: - Private: PTT Chunk Emission

    private func emitPTTChunk(flushFinalChunk: Bool = false) {
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

        let pcmData = extractPCMData(fromRecordedFileData: data)
        let previousLength = accumulatedPCMData.count

        if pcmData.count > previousLength {
            pendingPTTPCMData.append(pcmData[previousLength...])
            accumulatedPCMData = pcmData
        }

        guard !pendingPTTPCMData.isEmpty else { return }

        do {
            let (encoded, remainder) = try encodePCMFramesAsOpus(
                pendingPTTPCMData,
                bitrate: Self.pttBitrate,
                padFinalFrame: flushFinalChunk
            )
            pendingPTTPCMData = remainder

            guard !encoded.isEmpty else { return }
            delegate?.audioService(self, didRecordChunk: encoded, duration: recordingDuration)
        } catch {
            // Tell the delegate (PTTViewModel) so the UI can surface a real error
            // instead of getting stuck in "sending" forever. Logging alone wasn't
            // enough — the operator never saw the failure.
            logger.warning("Failed to encode PTT audio chunk: \(error.localizedDescription)")
            let serviceError: AudioServiceError = (error as? AudioServiceError)
                ?? .encodingFailed(error.localizedDescription)
            delegate?.audioService(self, didFailWithError: serviceError)
        }
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

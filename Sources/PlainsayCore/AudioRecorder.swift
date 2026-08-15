import AVFoundation
import Foundation

public enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable(from: AVAudioFormat)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            "No audio input device available."
        case .converterUnavailable(let format):
            "Cannot convert audio from \(format.sampleRate)Hz to 16kHz mono."
        case .engineFailed(let message):
            "Audio engine failed: \(message)"
        }
    }
}

/// Local speech models expect 16kHz mono float samples; hardware rarely provides them directly.
public let whisperSampleRate: Double = 16_000

/// Owns the converter and output buffer used on the realtime audio thread.
///
/// Unchecked `Sendable` because it is only ever touched from CoreAudio's tap
/// callback, which is serial. Nothing else may call `process`.
private final class AudioTapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer
    private let sink: AudioSampleSink

    init?(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, sink: AudioSampleSink, maxInputFrames: AVAudioFrameCount) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }
        // Downsampling only shrinks the frame count, but reserve the input size
        // anyway so an upsampling input device cannot overrun the buffer.
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(maxInputFrames) * max(1, ratio)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        self.converter = converter
        self.outputBuffer = output
        self.sink = sink
    }

    func process(_ input: AVAudioPCMBuffer) {
        outputBuffer.frameLength = 0

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil,
              let channel = outputBuffer.floatChannelData?[0],
              outputBuffer.frameLength > 0
        else { return }

        sink.append(channel, count: Int(outputBuffer.frameLength))
    }
}

/// Microphone capture, behind a protocol so the pipeline can be driven by a
/// fake in tests without touching CoreAudio.
@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    /// 0...1, for the HUD meter.
    var normalizedLevel: Float { get }
    var elapsed: TimeInterval { get }

    func start() throws
    /// Stops and returns the recording as 16kHz mono floats.
    @discardableResult func stop() -> [Float]
    /// Stops and throws the audio away.
    func cancel()
}

/// Captures microphone audio as 16kHz mono float samples.
@MainActor
public final class AudioRecorder: AudioRecording {
    public private(set) var isRecording = false

    /// Rebuilt whenever the audio hardware changes underneath us.
    ///
    /// `AVAudioEngine` binds to the input device it saw when its `inputNode`
    /// was first touched. If the default input changes afterwards — headphones
    /// connect, a dock is plugged in, a call ends — the engine keeps pulling
    /// from the old device and quietly delivers silence forever. A single
    /// long-lived engine therefore breaks permanently the first time hardware
    /// changes, which looks exactly like "dictation randomly stopped working".
    private var engine = AVAudioEngine()
    private let sink = AudioSampleSink()
    private var processor: AudioTapProcessor?
    private var startedAt: Date?
    private var configurationObserver: (any NSObjectProtocol)?

    /// Frames requested per tap callback. 4096 at 48kHz is ~85ms — small enough
    /// for a responsive level meter, large enough to keep overhead low.
    private static let tapBufferSize: AVAudioFrameCount = 4096

    public init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    /// Throws away the engine so the next recording binds to the current device.
    private func handleConfigurationChange() {
        Log.audio.info("audio configuration changed — rebuilding engine")
        guard !isRecording else {
            // Mid-recording: keep what we have rather than losing the audio.
            // The next recording gets the fresh engine.
            needsEngineRebuild = true
            return
        }
        rebuildEngine()
    }

    private var needsEngineRebuild = false

    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        processor = nil
        needsEngineRebuild = false
    }

    /// Builds the tap callback in a `nonisolated` context.
    ///
    /// This must not be a closure written inline in `start()`. `AudioRecorder`
    /// is `@MainActor`, so a closure created there inherits main-actor
    /// isolation and Swift emits a runtime isolation assertion inside it.
    /// CoreAudio invokes this block on the realtime audio thread, the
    /// assertion fails, and the process traps in `dispatch_assert_queue_fail`
    /// the instant recording starts.
    private nonisolated static func makeTapBlock(
        _ processor: AudioTapProcessor
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            processor.process(buffer)
        }
    }

    /// Live input level, 0...1, for the recording HUD.
    public var normalizedLevel: Float { sink.normalizedLevel }

    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() throws {
        guard !isRecording else { return }
        guard Self.microphoneAuthorized() else { throw AudioRecorderError.microphoneDenied }

        if needsEngineRebuild { rebuildEngine() }

        sink.reset()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.converterUnavailable(from: inputFormat)
        }

        guard let processor = AudioTapProcessor(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            sink: sink,
            maxInputFrames: Self.tapBufferSize
        ) else {
            throw AudioRecorderError.converterUnavailable(from: inputFormat)
        }
        self.processor = processor

        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat,
            block: Self.makeTapBlock(processor)
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.processor = nil
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }

        startedAt = Date()
        isRecording = true
    }

    /// Stops capture and returns everything recorded, as 16kHz mono floats.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor = nil
        isRecording = false
        startedAt = nil

        let samples = sink.drain()

        // Peak amplitude is the one number that separates "the model heard
        // nothing" from "the microphone captured nothing". Without it, an empty
        // transcript is unattributable.
        var peak: Float = 0
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        Log.audio.info("""
            captured \(samples.count, privacy: .public) samples \
            (\(Double(samples.count) / whisperSampleRate, format: .fixed(precision: 2), privacy: .public)s), \
            peak=\(peak, format: .fixed(precision: 4), privacy: .public), \
            device=\(self.currentInputDeviceName, privacy: .public)
            """)
        if peak < 0.001 {
            Log.audio.error("microphone captured silence — input device may have changed since launch")
        }

        return samples
    }

    /// Name of the current default input, for the log line above.
    private var currentInputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
    }

    /// Stops and discards — used when a dictation is cancelled.
    public func cancel() {
        _ = stop()
        sink.reset()
    }
}

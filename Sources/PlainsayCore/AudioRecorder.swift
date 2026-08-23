// The macOS 15 AVFAudio SDK predates Swift sendability annotations. Access to
// these objects is confined to the main actor or the explicitly serial audio
// tap processor below.
@preconcurrency import AVFoundation
import Foundation

public enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable(sampleRate: Double)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            Localization.coreString(
                "audio.microphoneDenied",
                fallback: "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
            )
        case .noInputDevice:
            Localization.coreString("audio.noInputDevice", fallback: "No audio input device available.")
        case .converterUnavailable(let sampleRate):
            Localization.coreFormat(
                "audio.converterUnavailable", fallback: "Cannot convert audio from %@Hz to 16kHz mono.",
                String(sampleRate)
            )
        case .engineFailed(let message):
            Localization.coreFormat("audio.engineFailed", fallback: "Audio engine failed: %@", message)
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
    /// Becomes true at the capture boundary, before another audio callback has
    /// to discard samples. The coordinator turns this into an automatic stop.
    var hasReachedMaximumDuration: Bool { get }

    func start() throws
    /// Stops and returns the recording as 16kHz mono floats.
    @discardableResult func stop() -> [Float]
    /// Stops and throws the audio away.
    func cancel()
    /// Everything captured so far, without stopping. Safe to call repeatedly
    /// mid-recording — for a live transcription preview, not for `stop()`.
    func peek() -> [Float]
}

public extension AudioRecording {
    /// Custom recorders that are not duration-bounded remain compatible; the
    /// production `AudioRecorder` overrides this with its sample-buffer state.
    var hasReachedMaximumDuration: Bool { false }
}

/// Captures microphone audio as 16kHz mono float samples.
@MainActor
public final class AudioRecorder: AudioRecording {
    public static let maximumDuration: TimeInterval = 10 * 60

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
    private let sink = AudioSampleSink(seconds: AudioRecorder.maximumDuration)
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
        guard !isRecording else {
            // Not merely "the next recording needs a fresh engine". The engine
            // stops its own graph on a configuration change and drops the
            // installed tap with it, so from this instant the sink stops
            // growing: every word spoken after it is gone, and the recording
            // ends wherever the device changed rather than where the speaker
            // stopped. Keeping quiet about that produces a transcript that
            // ends mid-sentence with nothing anywhere saying why.
            Log.audio.error("audio configuration changed mid-recording — capture has stopped; audio after this point is lost")
            captureWasInterrupted = true
            needsEngineRebuild = true
            return
        }
        Log.audio.info("audio configuration changed — rebuilding engine")
        rebuildEngine()
    }

    private var needsEngineRebuild = false

    /// True when capture was cut short by the audio hardware changing under
    /// the recording rather than by the speaker stopping it.
    public private(set) var captureWasInterrupted = false

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

    /// Ten minutes of 16kHz mono audio is the bounded in-memory capture. The
    /// coordinator observes this exact sample boundary and stops the recorder;
    /// it does not infer the cutoff from wall-clock time.
    public var hasReachedMaximumDuration: Bool { sink.isAtCapacity }

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

        captureWasInterrupted = false
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
            throw AudioRecorderError.converterUnavailable(sampleRate: inputFormat.sampleRate)
        }

        guard let processor = AudioTapProcessor(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            sink: sink,
            maxInputFrames: Self.tapBufferSize
        ) else {
            throw AudioRecorderError.converterUnavailable(sampleRate: inputFormat.sampleRate)
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
        // Read before `startedAt` is discarded: this is the only place both
        // how long the speaker held the key and how much audio actually
        // arrived are known at once, and their difference is the one number
        // that separates "the recording ended where I stopped talking" from
        // "capture died early and the transcript lost the rest".
        let heldFor = elapsed
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor = nil
        isRecording = false
        startedAt = nil

        let samples = sink.drain()
        let shortfall = Self.captureShortfall(heldFor: heldFor, capturedSamples: samples.count)

        // Peak amplitude is the one number that separates "the model heard
        // nothing" from "the microphone captured nothing". Without it, an empty
        // transcript is unattributable.
        var peak: Float = 0
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        Log.audio.info("""
            captured \(samples.count, privacy: .public) samples \
            (\(Double(samples.count) / whisperSampleRate, format: .fixed(precision: 2), privacy: .public)s), \
            held=\(heldFor, format: .fixed(precision: 2), privacy: .public)s, \
            shortfall=\(shortfall, format: .fixed(precision: 2), privacy: .public)s, \
            peak=\(peak, format: .fixed(precision: 4), privacy: .public), \
            device=\(self.currentInputDeviceName, privacy: .public)
            """)
        if peak < 0.001 {
            Log.audio.error("microphone captured silence — input device may have changed since launch")
        }
        if captureWasInterrupted {
            Log.audio.error("""
                recording ended by an audio configuration change, not by the speaker — \
                \(shortfall, format: .fixed(precision: 2), privacy: .public)s of speech was never captured
                """)
        } else if shortfall > Self.captureShortfallTolerance {
            // A transcript that stops mid-sentence is otherwise unattributable:
            // the recognizer and the editing pass both look innocent because
            // the audio they were handed really did end there.
            Log.audio.error("""
                capture fell \(shortfall, format: .fixed(precision: 2), privacy: .public)s short of the \
                \(heldFor, format: .fixed(precision: 2), privacy: .public)s held — \
                speech from the end of this recording is missing
                """)
        }

        return samples
    }

    /// Audio the speaker produced that never reached the sink.
    ///
    /// Capture always ends on a tap-buffer boundary, so a small shortfall is
    /// normal and expected — one 4096-frame buffer is ~85ms. Anything beyond
    /// the tolerance means samples stopped arriving before the speaker
    /// stopped speaking, which is the difference between a transcript that
    /// merely clips a syllable and one that loses a clause.
    nonisolated static func captureShortfall(heldFor: TimeInterval, capturedSamples: Int) -> TimeInterval {
        max(0, heldFor - Double(capturedSamples) / whisperSampleRate)
    }

    /// One tap buffer at 48kHz plus room for the hardware's own input
    /// latency. Below this, the loss is a fraction of a word and inherent to
    /// stopping on a buffer boundary.
    nonisolated static let captureShortfallTolerance: TimeInterval = 0.5

    /// Name of the current default input, for the log line above.
    private var currentInputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
    }

    /// Stops and discards — used when a dictation is cancelled.
    public func cancel() {
        _ = stop()
        sink.reset()
    }

    /// `AudioSampleSink.drain()` only copies what's written; it never resets
    /// the write cursor, so calling it mid-recording is exactly a peek.
    public func peek() -> [Float] {
        sink.drain()
    }
}

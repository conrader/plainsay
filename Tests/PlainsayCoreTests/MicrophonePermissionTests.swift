import AVFoundation
import Testing

@testable import PlainsayCore

/// Reported as conrader/plainsay#49: the microphone prompt never appeared and
/// Plainsay never showed up in System Settings › Privacy & Security ›
/// Microphone at all, so there was nothing to switch on. Accessibility and
/// Input Monitoring registered from the same install.
///
/// `requestAccess` is what puts an app in that list. Skipping it for every
/// status except `.notDetermined` means a Mac whose TCC record says anything
/// else can never be recovered from inside the app *or* from System Settings.
@Suite("Microphone authorization")
struct MicrophonePermissionTests {
    @Test("A denied status still asks the system, which is what registers the app")
    func deniedStillAsks() {
        #expect(AudioRecorder.shouldAskSystemForMicrophone(.denied))
    }

    @Test("A restricted status still asks rather than giving up")
    func restrictedStillAsks() {
        #expect(AudioRecorder.shouldAskSystemForMicrophone(.restricted))
    }

    @Test("Never having been asked still asks")
    func notDeterminedAsks() {
        #expect(AudioRecorder.shouldAskSystemForMicrophone(.notDetermined))
    }

    @Test("An already-granted microphone is not asked for again")
    func authorizedDoesNotAsk() {
        #expect(!AudioRecorder.shouldAskSystemForMicrophone(.authorized))
    }
}

/// The path in the report: Settings › Voice recognition › "Record my voice…".
/// It went straight to `recorder.start()`, which only *checks* the status and
/// throws — so the one call that would have raised the dialog, and registered
/// Plainsay in System Settings, was never made from the button the user was
/// told to press.
@Suite("Voice enrollment microphone")
@MainActor
struct VoiceEnrollmentMicrophoneTests {
    final class SilentRecorder: AudioRecording {
        var isRecording = false
        var normalizedLevel: Float = 0
        var elapsed: TimeInterval = 0
        var didStart = false
        func start() throws { didStart = true; isRecording = true }
        func stop() -> [Float] { isRecording = false; return [] }
        func cancel() { isRecording = false }
        func peek() -> [Float] { [] }
    }

    @Test("Enrolling asks macOS for the microphone instead of only reading the status")
    func asksBeforeRecording() async throws {
        let recorder = SilentRecorder()
        var asked = false
        let enrollment = VoiceEnrollment(recorder: recorder, requestMicrophone: { asked = true; return true })

        try await enrollment.start()

        #expect(asked)
        #expect(recorder.didStart)
    }

    @Test("A refused microphone stops enrollment rather than recording silence")
    func refusalStopsEnrollment() async {
        let recorder = SilentRecorder()
        let enrollment = VoiceEnrollment(recorder: recorder, requestMicrophone: { false })

        await #expect(throws: AudioRecorderError.self) { try await enrollment.start() }
        #expect(!recorder.didStart)
    }
}

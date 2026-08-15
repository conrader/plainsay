import Testing
@testable import PlainsayCore

@Suite("Speech model load progress")
struct ModelLoadStateTests {
    @Test("Progress is always finite and clamped")
    func clampsProgress() {
        #expect(SpeechModelLoadState.clampedProgress(-0.25) == 0)
        #expect(SpeechModelLoadState.clampedProgress(0.4) == 0.4)
        #expect(SpeechModelLoadState.clampedProgress(1.25) == 1)
        #expect(SpeechModelLoadState.clampedProgress(.nan) == 0)
        #expect(SpeechModelLoadState.clampedProgress(-.infinity) == 0)
        #expect(SpeechModelLoadState.clampedProgress(.infinity) == 1)
    }

    @Test("Parakeet never regresses after FluidAudio starts compiling")
    func mapsParakeetProgress() {
        var presentation = ParakeetEngine.ProgressPresentation()

        #expect(presentation.state(
            fractionCompleted: 0.25,
            isCompiling: false
        ) == .downloading(progress: 0.5))
        #expect(presentation.state(
            fractionCompleted: 0.5,
            isCompiling: false
        ) == .downloading(progress: 1))
        #expect(presentation.state(
            fractionCompleted: 0.5,
            isCompiling: true
        ) == .loading(progress: nil))

        // The next FluidAudio sub-operation restarts at listing/downloading 0.
        // It must not make Plainsay jump back to Downloading.
        #expect(presentation.state(
            fractionCompleted: 0,
            isCompiling: false
        ) == nil)
    }
}

import Foundation
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

    @Test("Download watchdog fires at 90 seconds without forward progress")
    func downloadWatchdogBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let active = SpeechModelLoadWatchdog(
            state: .downloading(progress: 0.5),
            timing: SpeechModelLoadTiming(
                phase: .downloading,
                startedAt: Date(timeIntervalSince1970: 800),
                lastDownloadProgressAt: Date(timeIntervalSince1970: 911)
            ),
            now: now
        )
        #expect(active.attention == nil)
        #expect(active.recoveryAction == nil)

        let stalled = SpeechModelLoadWatchdog(
            state: .downloading(progress: 0.5),
            timing: SpeechModelLoadTiming(
                phase: .downloading,
                startedAt: Date(timeIntervalSince1970: 800),
                lastDownloadProgressAt: Date(timeIntervalSince1970: 910)
            ),
            now: now
        )
        #expect(stalled.attention == .downloadStalled)
        #expect(stalled.recoveryAction == .retry)

        let actionRequired = SpeechModelLoadWatchdog(
            state: .downloading(progress: 0.5),
            timing: SpeechModelLoadTiming(
                phase: .downloading,
                startedAt: Date(timeIntervalSince1970: 600),
                lastDownloadProgressAt: Date(timeIntervalSince1970: 700)
            ),
            now: now
        )
        #expect(actionRequired.attention == .downloadActionRequired)
        #expect(actionRequired.recoveryAction == .restart)
    }

    @Test("Preparation escalates at three, eight, and fifteen minutes")
    func preparationWatchdogBoundaries() {
        let now = Date(timeIntervalSince1970: 2_000)
        func watchdog(after seconds: TimeInterval) -> SpeechModelLoadWatchdog {
            SpeechModelLoadWatchdog(
                state: .loading(progress: nil),
                timing: SpeechModelLoadTiming(
                    phase: .preparing,
                    startedAt: now.addingTimeInterval(-seconds),
                    lastDownloadProgressAt: nil
                ),
                now: now
            )
        }

        #expect(watchdog(after: 179).attention == nil)
        #expect(watchdog(after: 180).attention == .firstPreparation)
        #expect(watchdog(after: 480).attention == .takingLonger)
        #expect(watchdog(after: 899).recoveryAction == nil)
        #expect(watchdog(after: 900).attention == .actionRequired)
        #expect(watchdog(after: 900).recoveryAction == .restart)
    }

    @Test("Elapsed time formatting crosses the hour boundary cleanly")
    func elapsedTimecode() {
        #expect(SpeechModelLoadWatchdog.timecode(-1) == "0:00")
        #expect(SpeechModelLoadWatchdog.timecode(59) == "0:59")
        #expect(SpeechModelLoadWatchdog.timecode(3_599) == "59:59")
        #expect(SpeechModelLoadWatchdog.timecode(3_600) == "1:00:00")
    }

    @Test("A terminal model failure offers a normal retry")
    func failureRecovery() {
        let watchdog = SpeechModelLoadWatchdog(
            state: .failed("network"),
            timing: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(watchdog.recoveryAction == .retry)
    }
}

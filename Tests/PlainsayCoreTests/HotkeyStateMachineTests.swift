import CoreGraphics
import Testing
@testable import PlainsayCore

@Suite("Hotkey hold-vs-tap")
struct HotkeyStateMachineTests {
    @Test("A long press records for exactly as long as it is held")
    func longPressIsPushToTalk() {
        var machine = HotkeyStateMachine(mode: .hybrid, tapThreshold: 0.25)

        #expect(machine.handle(.down(at: 0)) == .start)
        #expect(machine.isRecording)
        #expect(machine.handle(.up(at: 1.5)) == .stop)
        #expect(!machine.isRecording)
    }

    @Test("A quick tap latches recording on until the next press")
    func quickTapLatches() {
        var machine = HotkeyStateMachine(mode: .hybrid, tapThreshold: 0.25)

        #expect(machine.handle(.down(at: 0)) == .start)
        // Released quickly: keep recording rather than stopping.
        #expect(machine.handle(.up(at: 0.1)) == .none)
        #expect(machine.isRecording)

        // Second tap ends it...
        #expect(machine.handle(.down(at: 5.0)) == .stop)
        #expect(!machine.isRecording)
        // ...and its release must not start a new recording.
        #expect(machine.handle(.up(at: 5.05)) == .none)
        #expect(!machine.isRecording)
    }

    @Test("A press exactly at the threshold counts as a hold")
    func thresholdBoundaryIsHold() {
        var machine = HotkeyStateMachine(mode: .hybrid, tapThreshold: 0.25)

        _ = machine.handle(.down(at: 0))
        #expect(machine.handle(.up(at: 0.25)) == .stop)
    }

    @Test("Latched recording survives a stray release")
    func strayReleaseWhileLatchedIsIgnored() {
        var machine = HotkeyStateMachine(mode: .hybrid, tapThreshold: 0.25)

        _ = machine.handle(.down(at: 0))
        _ = machine.handle(.up(at: 0.1))
        #expect(machine.handle(.up(at: 0.2)) == .none)
        #expect(machine.isRecording)
    }

    @Test("Hold-only mode never latches")
    func holdOnlyIgnoresTaps() {
        var machine = HotkeyStateMachine(mode: .holdOnly, tapThreshold: 0.25)

        #expect(machine.handle(.down(at: 0)) == .start)
        #expect(machine.handle(.up(at: 0.01)) == .stop)
        #expect(!machine.isRecording)
    }

    @Test("Toggle-only mode ignores releases entirely")
    func toggleOnlyUsesPressesOnly() {
        var machine = HotkeyStateMachine(mode: .toggleOnly)

        #expect(machine.handle(.down(at: 0)) == .start)
        #expect(machine.handle(.up(at: 0.01)) == .none)
        #expect(machine.isRecording)
        #expect(machine.handle(.down(at: 3)) == .stop)
        #expect(!machine.isRecording)
    }

    @Test("Reset abandons an in-flight press without emitting a command")
    func resetClearsState() {
        var machine = HotkeyStateMachine(mode: .hybrid)

        _ = machine.handle(.down(at: 0))
        machine.reset()

        #expect(!machine.isRecording)
        // The stranded release must not be read as the end of a recording.
        #expect(machine.handle(.up(at: 1)) == .none)
    }
}

@Suite("Hotkey monitor")
@MainActor
struct HotkeyMonitorTests {
    @Test("Escape emits one cancellation and ignores key repeat")
    func escapeCancelsOnce() {
        let monitor = HotkeyMonitor()
        var cancellationCount = 0
        monitor.onCancel = { cancellationCount += 1 }

        monitor.handle(type: .keyDown, keyCode: 53, flags: 0, isAutorepeat: false)
        monitor.handle(type: .keyDown, keyCode: 53, flags: 0, isAutorepeat: true)
        monitor.handle(type: .keyUp, keyCode: 53, flags: 0, isAutorepeat: false)

        #expect(cancellationCount == 1)
    }
}

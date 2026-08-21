import AppKit
import Testing
@testable import PlainsayCore

@Suite("Audio sample sink")
struct AudioSampleSinkTests {
    @Test("Appended samples come back in order")
    func appendAndDrain() {
        let sink = AudioSampleSink(seconds: 1, sampleRate: 100)
        var samples: [Float] = [0.1, 0.2, 0.3]

        samples.withUnsafeBufferPointer { sink.append($0.baseAddress!, count: $0.count) }

        #expect(sink.count == 3)
        #expect(sink.drain() == [0.1, 0.2, 0.3])
    }

    @Test("Writing past capacity truncates and flags the overflow")
    func overflowIsBounded() {
        let sink = AudioSampleSink(seconds: 1, sampleRate: 4)
        var samples = [Float](repeating: 0.5, count: 10)

        samples.withUnsafeBufferPointer { sink.append($0.baseAddress!, count: $0.count) }

        #expect(sink.count == 4)
        #expect(sink.didOverflow)
    }

    @Test("Reset rewinds for the next recording")
    func resetClears() {
        let sink = AudioSampleSink(seconds: 1, sampleRate: 100)
        var samples: [Float] = [0.4, 0.4]
        samples.withUnsafeBufferPointer { sink.append($0.baseAddress!, count: $0.count) }

        sink.reset()

        #expect(sink.count == 0)
        #expect(sink.drain().isEmpty)
        #expect(sink.level == 0)
    }

    @Test("Silence reads as zero on the meter, loud audio near full")
    func levelMapping() {
        let quiet = AudioSampleSink(seconds: 1, sampleRate: 100)
        var silence = [Float](repeating: 0, count: 10)
        silence.withUnsafeBufferPointer { quiet.append($0.baseAddress!, count: $0.count) }
        #expect(quiet.normalizedLevel == 0)

        let loud = AudioSampleSink(seconds: 1, sampleRate: 100)
        var full = [Float](repeating: 1.0, count: 10)
        full.withUnsafeBufferPointer { loud.append($0.baseAddress!, count: $0.count) }
        #expect(loud.normalizedLevel > 0.95)
    }
}

@Suite("Pasteboard handling")
@MainActor
struct PasteboardSnapshotTests {
    /// A private pasteboard: these tests must not touch the user's clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.plainsay.tests.\(UUID().uuidString)"))
    }

    @Test("Text survives a snapshot and restore")
    func roundTripsText() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        #expect(pasteboard.string(forType: .string) == "dictated text")

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }

    @Test("Non-text contents are preserved too")
    func roundTripsArbitraryData() throws {
        let pasteboard = makePasteboard()
        let type = NSPasteboard.PasteboardType("public.png")
        let payload = Data([0x89, 0x50, 0x4E, 0x47])

        pasteboard.clearContents()
        pasteboard.setData(payload, forType: type)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        snapshot.restore(to: pasteboard)

        #expect(pasteboard.data(forType: type) == payload)
    }

    @Test("Restoring an empty snapshot leaves the pasteboard empty, not stale")
    func emptySnapshotClears() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        #expect(snapshot.isEmpty)

        pasteboard.setString("dictated text", forType: .string)
        snapshot.restore(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("A definite empty focus result suppresses synthetic paste")
    func definiteMissingFocusSuppressesPaste() {
        let successfulEmpty = PasteboardTextInserter.accessibilityValueState(
            queryResult: .success,
            valuePresent: false
        )
        let explicitNoValue = PasteboardTextInserter.accessibilityValueState(
            queryResult: .noValue,
            valuePresent: false
        )

        #expect(successfulEmpty == .absent)
        #expect(explicitNoValue == .absent)
        #expect(!PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: successfulEmpty,
            focusedWindow: explicitNoValue,
            allowsFocusedWindowFallback: false
        ))
    }

    @Test("Accessibility query errors require a focused window")
    func uncertainFocusRequiresWindow() {
        let focused = PasteboardTextInserter.accessibilityValueState(
            queryResult: .success,
            valuePresent: true
        )
        let busy = PasteboardTextInserter.accessibilityValueState(
            queryResult: .cannotComplete,
            valuePresent: false
        )
        let unsupported = PasteboardTextInserter.accessibilityValueState(
            queryResult: .attributeUnsupported,
            valuePresent: false
        )

        #expect(focused == .present)
        #expect(busy == .unknown)
        #expect(unsupported == .unknown)
        #expect(!PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: busy,
            focusedWindow: .absent,
            allowsFocusedWindowFallback: false
        ))
        #expect(PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: busy,
            focusedWindow: focused,
            allowsFocusedWindowFallback: false
        ))
        #expect(PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: focused,
            focusedWindow: .absent,
            allowsFocusedWindowFallback: false
        ))
    }

    @Test("ChatGPT can use its focused window when its custom editor is hidden from Accessibility")
    func chatGPTFocusedWindowFallback() {
        #expect(PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: .absent,
            focusedWindow: .present,
            allowsFocusedWindowFallback: true
        ))
        #expect(!PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: .absent,
            focusedWindow: .present,
            allowsFocusedWindowFallback: false
        ))
    }
}

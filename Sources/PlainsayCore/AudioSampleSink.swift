import Foundation
import Synchronization

/// Single-producer/single-consumer append-only sample buffer.
///
/// The producer is CoreAudio's realtime render thread, where allocating or
/// taking a lock risks a dropout. Storage is therefore preallocated once and the
/// write cursor is a plain atomic: the audio thread only ever memcpys and bumps
/// an index, and the consumer only ever reads below that index.
public final class AudioSampleSink: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    /// Latest RMS, stored as a bit pattern so it can live in an atomic.
    private let levelBits = Atomic<UInt32>(0)
    /// Set when audio arrived after the buffer filled up.
    private let overflowed = Atomic<Bool>(false)

    /// - Parameter seconds: how much audio to reserve room for. Recording stops
    ///   accepting samples past this; ten minutes is far beyond any dictation.
    public init(seconds: Double = 600, sampleRate: Double = 16_000) {
        capacity = Int(seconds * sampleRate)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    // MARK: - Producer (realtime audio thread)

    /// Appends samples and updates the level meter. Realtime-safe.
    public func append(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        let start = writeIndex.load(ordering: .relaxed)
        let room = capacity - start
        guard room > 0 else {
            overflowed.store(true, ordering: .relaxed)
            return
        }
        let n = min(count, room)
        if n < count { overflowed.store(true, ordering: .relaxed) }

        storage.advanced(by: start).update(from: samples, count: n)
        // Release so the consumer sees the samples before it sees the index.
        writeIndex.store(start + n, ordering: .releasing)

        var sumOfSquares: Float = 0
        for i in 0..<n { sumOfSquares += samples[i] * samples[i] }
        let rms = (sumOfSquares / Float(n)).squareRoot()
        levelBits.store(rms.bitPattern, ordering: .relaxed)
    }

    // MARK: - Consumer

    public var count: Int { writeIndex.load(ordering: .acquiring) }

    public var didOverflow: Bool { overflowed.load(ordering: .relaxed) }

    /// Raw RMS of the most recent buffer, roughly 0...1.
    public var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    /// Perceptual 0...1 level suitable for driving a meter, mapping roughly
    /// -50 dBFS...0 dBFS onto the full range.
    public var normalizedLevel: Float {
        let rms = level
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }

    /// Copies out everything written so far.
    public func drain() -> [Float] {
        let n = writeIndex.load(ordering: .acquiring)
        guard n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: storage, count: n))
    }

    /// Rewinds for a new recording. Only safe while the producer is stopped.
    public func reset() {
        writeIndex.store(0, ordering: .releasing)
        levelBits.store(0, ordering: .relaxed)
        overflowed.store(false, ordering: .relaxed)
    }
}

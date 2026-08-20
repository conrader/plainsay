import Foundation
import os

/// Single-producer/single-consumer append-only sample buffer.
///
/// The producer is CoreAudio's realtime render thread, where allocating or
/// blocking risks a dropout. Storage is therefore preallocated once, and all
/// mutable state is protected by `os_unfair_lock` — safe to take from a
/// realtime thread because its uncontended fast path never makes a syscall,
/// unlike `pthread_mutex`/`NSLock`. (Not `Synchronization.Atomic`: that type
/// is macOS 15+ only, and this needs to run on Sonoma.)
public final class AudioSampleSink: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: os_unfair_lock_t

    private var writeIndexValue = 0
    private var levelBitsValue: UInt32 = 0
    private var overflowedValue = false

    /// - Parameter seconds: how much audio to reserve room for. Recording stops
    ///   accepting samples past this; ten minutes is far beyond any dictation.
    public init(seconds: Double = 600, sampleRate: Double = 16_000) {
        capacity = Int(seconds * sampleRate)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Producer (realtime audio thread)

    /// Appends samples and updates the level meter. Realtime-safe.
    public func append(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        os_unfair_lock_lock(lock)

        let start = writeIndexValue
        let room = capacity - start
        guard room > 0 else {
            overflowedValue = true
            os_unfair_lock_unlock(lock)
            return
        }
        let n = min(count, room)
        if n < count { overflowedValue = true }

        storage.advanced(by: start).update(from: samples, count: n)
        writeIndexValue = start + n

        var sumOfSquares: Float = 0
        for i in 0..<n { sumOfSquares += samples[i] * samples[i] }
        let rms = (sumOfSquares / Float(n)).squareRoot()
        levelBitsValue = rms.bitPattern

        os_unfair_lock_unlock(lock)
    }

    // MARK: - Consumer

    public var count: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writeIndexValue
    }

    public var didOverflow: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return overflowedValue
    }

    /// Raw RMS of the most recent buffer, roughly 0...1.
    public var level: Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Float(bitPattern: levelBitsValue)
    }

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
        os_unfair_lock_lock(lock)
        let n = writeIndexValue
        os_unfair_lock_unlock(lock)
        guard n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: storage, count: n))
    }

    /// Rewinds for a new recording. Only safe while the producer is stopped.
    public func reset() {
        os_unfair_lock_lock(lock)
        writeIndexValue = 0
        levelBitsValue = 0
        overflowedValue = false
        os_unfair_lock_unlock(lock)
    }
}

import Foundation

/// Holds captured audio on disk between recording and transcription.
///
/// Until it is transcribed, a dictation exists only as a `[Float]` in memory.
/// Anything that ends the process in that window — a crash, a rebuild, a
/// force-quit — destroys it with no trace, and transcription is the slowest
/// stage, so that window is seconds wide on every single dictation.
///
/// Writing the samples down first makes the loss recoverable: whatever is still
/// here at the next launch never got transcribed, and can be picked up.
public struct PendingAudioStore: Sendable {
    private let directory: URL

    /// How long an un-recovered recording is kept before `prune` discards it,
    /// and how many are kept regardless of age. Recovery normally clears these
    /// within a launch or two; the caps bound the failure case where recovery
    /// cannot run (the model never becomes ready) or keeps failing, so raw voice
    /// audio does not accumulate on disk forever with no way to notice.
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maxCount = 20

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plainsay/pending", isDirectory: true)
        self.directory = base
        PrivateFiles.makePrivateDirectory(at: base)
    }

    /// Writes samples as raw little-endian Float32 and returns their handle.
    @discardableResult
    public func save(_ samples: [Float]) -> URL? {
        guard !samples.isEmpty else { return nil }
        let url = directory.appendingPathComponent("\(UUID().uuidString).f32")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: url, options: .atomic)
            PrivateFiles.protectWrittenFile(url)
            return url
        } catch {
            // Not fatal: the dictation still works, it just isn't recoverable.
            Log.audio.error("could not stage audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Called once the audio has been through the pipeline.
    public func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Anything left here was interrupted before it could be transcribed.
    public func recoverable() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "f32" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    public func load(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Discards staged audio older than `maxAge`, and the oldest beyond
    /// `maxCount`, so a machine where recovery cannot run does not keep raw
    /// voice audio indefinitely. Safe to call at every launch, before recovery.
    public func prune(maxAge: TimeInterval = PendingAudioStore.maxAge, maxCount: Int = PendingAudioStore.maxCount) {
        let now = Date()
        // Oldest first, matching `recoverable()`.
        let files = recoverable()
        var survivors: [URL] = []
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maxAge {
                discard(url)
            } else {
                survivors.append(url)
            }
        }
        // Trim the oldest survivors past the count cap.
        if survivors.count > maxCount {
            for url in survivors.prefix(survivors.count - maxCount) {
                discard(url)
            }
        }
    }

    /// Removes every staged recording — the raw-audio counterpart to clearing
    /// transcript history.
    public func purgeAll() {
        for url in recoverable() {
            discard(url)
        }
    }
}

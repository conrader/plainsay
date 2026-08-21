import Foundation
import Testing
@testable import PlainsayCore

@Suite("Pending audio recovery")
struct PendingAudioStoreTests {
    private func makeStore() -> PendingAudioStore {
        PendingAudioStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("plainsay-pending-\(UUID().uuidString)")
        )
    }

    @Test("Staged audio is readable only by its owner, and skipped by backups")
    func stagedAudioIsPrivate() throws {
        // Raw recordings of the user's voice, sitting on disk between capture
        // and transcription. Same defaults problem as the transcript history
        // (external review #1): 0644 files in a 0755 directory, backed up.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-pending-\(UUID().uuidString)")
        let store = PendingAudioStore(directory: dir)
        let url = try #require(store.save([0.1, -0.2, 0.3]))

        func mode(_ u: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
            return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        #expect(try mode(url) == 0o600)
        #expect(try mode(dir) == 0o700)

        let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)
    }

    @Test("Samples survive a round trip through disk")
    func roundTrip() throws {
        let store = makeStore()
        let samples: [Float] = [0.1, -0.25, 0.5, 0]

        let url = try #require(store.save(samples))
        #expect(store.load(url) == samples)
    }

    @Test("Staged audio is listed as recoverable until it is discarded")
    func recoverableUntilDiscarded() throws {
        let store = makeStore()
        let url = try #require(store.save([0.1, 0.2]))

        // Compare filenames: /var is a symlink to /private/var, so the URLs
        // differ textually while pointing at the same file.
        #expect(store.recoverable().map(\.lastPathComponent) == [url.lastPathComponent])

        store.discard(url)
        #expect(store.recoverable().isEmpty)
    }

    @Test("Recoverable files come back oldest first")
    func recoveryIsOrdered() throws {
        let store = makeStore()
        let first = try #require(store.save([0.1]))
        // Distinct modification times; the filesystem stamps at write time.
        Thread.sleep(forTimeInterval: 0.05)
        let second = try #require(store.save([0.2]))

        #expect(
            store.recoverable().map(\.lastPathComponent)
                == [first.lastPathComponent, second.lastPathComponent]
        )
    }

    @Test("Empty audio is not staged at all")
    func emptyIsNotStaged() {
        let store = makeStore()

        #expect(store.save([]) == nil)
        #expect(store.recoverable().isEmpty)
    }

    @Test("Discarding nothing is harmless")
    func discardNilIsSafe() {
        makeStore().discard(nil)
    }
}

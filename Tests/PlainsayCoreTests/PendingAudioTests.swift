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

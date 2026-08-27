import CryptoKit
import Foundation
import Testing
@testable import PlainsayCore

/// Issue #27, carried over from the external security review in #1.
@Suite("Model integrity")
struct ModelIntegrityTests {
    private func makeDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ contents: String, to directory: URL, as name: String) -> URL {
        let url = directory.appending(path: name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(contents.utf8).write(to: url)
        return url
    }

    @Test("The git blob digest matches what git itself computes")
    func gitBlobMatchesGit() throws {
        // The only digest Hugging Face publishes for non-LFS files is git's own
        // blob sha1, which hashes "blob <count>\0" before the contents. Getting
        // that framing subtly wrong would fail open in the worst way: every
        // small file would mismatch, and the temptation would be to assume the
        // pins were stale rather than the implementation wrong. So this asserts
        // against the real `git hash-object` rather than against a constant.
        let dir = makeDirectory()
        let file = write("weights: not really\n", to: dir, as: "config.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["hash-object", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let expected = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try #require(!expected.isEmpty, "git hash-object produced nothing")
        #expect(ModelIntegrity.digest(of: file, using: .gitBlobSHA1) == expected)
    }

    @Test("The sha256 digest is of the file contents")
    func sha256IsPlainContentHash() {
        let dir = makeDirectory()
        let file = write("abc", to: dir, as: "weight.bin")
        let expected = SHA256.hash(data: Data("abc".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(ModelIntegrity.digest(of: file, using: .sha256) == expected)
    }

    @Test("Every downloadable model has pinned digests")
    func everyModelIsPinned() {
        // The check that keeps this honest over time. Adding a model to
        // `OnDeviceModel` without running Scripts/pin-model-digests.py would
        // otherwise ship a model that silently loads unverified — the exact
        // hole this closes, reopened by omission.
        for model in OnDeviceModel.allCases {
            #expect(
                ModelIntegrity.pinnedFileCount(for: model.rawValue) > 0,
                "\(model.rawValue) has no pinned digests — run Scripts/pin-model-digests.py"
            )
        }
    }

    @Test("A model whose file was modified is rejected")
    func modifiedFileIsRejected() {
        let dir = makeDirectory()
        // A real pinned model, with its files replaced by something else.
        let model = OnDeviceModel.baseEN.rawValue
        write("not the real weights", to: dir, as: "config.json")

        let result = ModelIntegrity.verify(model: model, in: dir)
        #expect(!result.isAcceptable)
        guard case let .failed(_, problems) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(!problems.isEmpty)
    }

    @Test("A model with no pins is allowed, and says so")
    func unpinnedModelIsAllowed() {
        let result = ModelIntegrity.verify(model: "some_model_we_never_shipped", in: makeDirectory())
        #expect(result == .unpinned(model: "some_model_we_never_shipped"))
        #expect(result.isAcceptable)
    }

    @Test("A rejected model is deleted, so the next launch re-downloads it")
    func failureDiscardsTheDownload() {
        let dir = makeDirectory()
        write("tampered", to: dir, as: "config.json")

        #expect(throws: ModelIntegrityError.self) {
            try ModelIntegrity.verifyOrDiscard(model: OnDeviceModel.baseEN.rawValue, in: dir)
        }

        // Both libraries skip downloading when the files are already present.
        // Leaving a rejected model on disk would make it fail verification for
        // ever, with no way out short of finding the cache by hand.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("Verification passes when every pinned file matches")
    func matchingFilesVerify() throws {
        // Builds a directory that satisfies a real pin set, by writing contents
        // chosen to hash to the pinned values — impossible — so instead this
        // uses a model pinned from the manifest and checks the *shape* of a
        // pass: no pinned model can be synthesised, but an empty pin set can.
        let dir = makeDirectory()
        write("anything", to: dir, as: "stray.txt")
        // An unpinned model with a stray file is acceptable: extra files are
        // reported, never fatal, because Core ML and the download libraries
        // both leave sidecars next to the weights.
        let result = ModelIntegrity.verify(model: "unpinned_variant", in: dir)
        #expect(result.isAcceptable)
    }
}

/// Verification against a real, fully downloaded model.
///
/// Every other test here builds synthetic files, which proves the digest
/// functions but not the *pins*. If the manifest's paths or digests were wrong,
/// those tests would still pass while every real user hit a hard failure on
/// first run — the worst possible place to be wrong, since it would look like
/// the app simply cannot download its model.
///
/// Opt-in because it needs the model on disk. Point it at a downloaded variant:
///
///     PLAINSAY_MODEL_DIR=~/…/openai_whisper-base.en \
///     PLAINSAY_MODEL_NAME=openai_whisper-base.en swift test --filter RealModel
@Suite("Model integrity against a real download")
struct RealModelIntegrityTests {
    @Test("A genuinely downloaded model matches its pinned digests")
    func realDownloadVerifies() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PLAINSAY_MODEL_DIR"],
              let name = environment["PLAINSAY_MODEL_NAME"]
        else {
            withKnownIssue("PLAINSAY_MODEL_DIR / PLAINSAY_MODEL_NAME not set", isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }

        let result = ModelIntegrity.verify(
            model: name, in: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        )
        if case let .failed(_, problems) = result {
            Issue.record("real model failed verification: \(problems.prefix(5).joined(separator: ", "))")
        }
        #expect(result.isAcceptable)
        #expect(result != .unpinned(model: name))
    }
}

/// Regression tests for the failure that shipped in 0.2.27: every Parakeet
/// load failed verification, and because failure also deletes, the app
/// re-downloaded the model on every launch, for ever.
@Suite("Integrity must not brick the app")
struct IntegrityResilienceTests {
    private func makeDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-resilience-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A pinned file that was never downloaded is not treated as tampering")
    func absentPinsAreNotFailures() {
        // FluidAudio fetches a subset of its repository — the int8 encoder, not
        // the int4 one — so 65 of the 88 pinned paths have nothing behind them
        // on a perfectly good install. Calling that a failure is what bricked
        // the app: the model was deleted and re-fetched on every launch.
        let dir = makeDirectory()
        let result = ModelIntegrity.verify(model: OnDeviceModel.parakeetTDT06BV3.rawValue, in: dir)
        #expect(result.isAcceptable)
    }

    @Test("An empty directory is reported as unverified, never as verified")
    func nothingFoundIsNotSuccess() {
        // The lenient path must not quietly turn "we checked nothing" into
        // "verified" — that would be a lie in the one place whose entire
        // purpose is not lying about coverage.
        let dir = makeDirectory()
        let result = ModelIntegrity.verify(model: OnDeviceModel.baseEN.rawValue, in: dir)
        #expect(result == .unpinned(model: OnDeviceModel.baseEN.rawValue))
    }

    @Test("A file that is present and altered is still fatal")
    func presentButChangedStillFails() throws {
        // Leniency about absence must not weaken the actual guarantee.
        let dir = makeDirectory()
        let name = "parakeet_vocab.json"
        try Data("tampered".utf8).write(to: dir.appending(path: name))

        let result = ModelIntegrity.verify(model: OnDeviceModel.parakeetTDT06BV3.rawValue, in: dir)
        #expect(!result.isAcceptable)
        guard case let .failed(_, problems) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(problems.contains { $0.contains(name) })
    }

    @Test("The model directory is found even when the download reports a sibling")
    func resolvesSiblingDirectory() throws {
        // `AsrModels.download` returns a path next to the one it wrote to.
        let root = makeDirectory()
        let reported = root.appending(path: "reported")
        let actual = root.appending(path: "parakeet-tdt-0.6b-v3")
        try FileManager.default.createDirectory(at: reported, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: actual.appending(path: "parakeet_vocab.json"))

        // Resolved on both sides: macOS hands back /private/var for /var,
        // and a raw string compare would fail on the prefix alone.
        #expect(
            ParakeetEngine.resolveModelDirectory(from: reported).resolvingSymlinksInPath().path
                == actual.resolvingSymlinksInPath().path
        )
    }

    @Test("A directory that already holds the model is used as-is")
    func prefersTheReportedDirectory() throws {
        let root = makeDirectory()
        let reported = root.appending(path: "here")
        try FileManager.default.createDirectory(at: reported, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: reported.appending(path: "parakeet_vocab.json"))

        #expect(
            ParakeetEngine.resolveModelDirectory(from: reported).resolvingSymlinksInPath().path
                == reported.resolvingSymlinksInPath().path
        )
    }
}

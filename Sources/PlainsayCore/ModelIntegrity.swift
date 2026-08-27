import CryptoKit
import Foundation
import os

/// Checks a downloaded speech model against digests shipped inside the app.
///
/// Everything Plainsay runs is signed and notarised except one thing: the
/// speech model, which is fetched over the network at first run and then
/// executed. Neither library we depend on closes that gap. WhisperKit hashes a
/// file only to decide whether an *already cached* copy can be reused, and
/// enforces a hash strictly only in offline mode — a freshly downloaded file is
/// written and returned unverified. FluidAudio uses ETags purely to resume
/// interrupted transfers and never hashes anything. Raised in the external
/// security review (#1, finding 6).
///
/// The digests live in `model-digests.json`, which travels inside the signed
/// app bundle. That is what makes this worth doing: an attacker who can change
/// what the model host serves cannot also change what we expect it to be.
/// Verifying against a hash fetched from the same host over the same connection
/// would prove only that the download was not corrupted in transit — which TLS
/// already tells us.
///
/// It remains a lockfile, not a signature. The pins record what the
/// repositories served when they were taken, exactly as `Package.resolved`
/// records what a dependency resolved to. It cannot say the upstream model was
/// honest that day; it says any later change is caught.
public enum ModelIntegrity {
    private static let logger = Logger(subsystem: Log.subsystem, category: "model-integrity")

    public enum Result: Equatable, Sendable {
        /// Every pinned file was present and matched.
        case verified(fileCount: Int)
        /// No pins are recorded for this model.
        case unpinned(model: String)
        /// A pinned file is missing, or its contents differ.
        case failed(model: String, problems: [String])

        public var isAcceptable: Bool {
            switch self {
            case .verified, .unpinned: true
            case .failed: false
            }
        }
    }

    struct Pin: Decodable, Equatable {
        enum Algorithm: String, Decodable {
            case sha256
            case gitBlobSHA1 = "git-blob-sha1"
        }
        let algorithm: Algorithm
        let digest: String
        let size: Int?
    }

    private struct Manifest: Decodable {
        struct Model: Decodable {
            let repo: String
            let commit: String
            let files: [String: Pin]
        }
        let models: [String: Model]
    }

    private static let manifest: Manifest? = {
        guard let url = Bundle.module.url(forResource: "model-digests", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            // Not fatal on its own — `verify` reports `.unpinned`, which the
            // caller logs. A missing resource is a build problem, and failing
            // every model load over it would turn a packaging slip into an app
            // that cannot transcribe at all.
            logger.error("model-digests.json is missing from the bundle — downloads cannot be verified")
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    /// How many files are pinned for `model`. Zero means none are.
    ///
    /// Separate from `verify` on purpose: verification answers "is what is on
    /// disk what we expect", which is unanswerable when nothing was downloaded.
    /// This answers "did anyone record what to expect", which is a fact about
    /// the shipped manifest and is the thing worth failing a build over.
    static func pinnedFileCount(for model: String) -> Int {
        manifest?.models[model]?.files.count ?? 0
    }

    /// Verifies `directory` against the pins recorded for `model`.
    ///
    /// Pinned files must be present and match. Files with no pin are reported
    /// but not treated as failures: the libraries write their own sidecars
    /// (`.cache/huggingface/…`, `.metadata`) next to the weights, and Core ML
    /// may leave artifacts of its own. An added file is not loaded by name and
    /// so does not execute, whereas failing on one would let a harmless
    /// packaging change brick transcription for everybody.
    public static func verify(model: String, in directory: URL) -> Result {
        guard let pins = manifest?.models[model]?.files, !pins.isEmpty else {
            logger.notice("no digests pinned for \(model, privacy: .public) — loading unverified")
            return .unpinned(model: model)
        }

        var problems: [String] = []
        var absent = 0
        var checked = 0
        for (relativePath, pin) in pins.sorted(by: { $0.key < $1.key }) {
            let file = directory.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: file.path) else {
                // Not a failure. A library that downloads a subset of a
                // repository, or lays it out differently from the repository
                // tree, leaves pinned paths with nothing behind them — and
                // that is a mistake in *our* manifest, not evidence about the
                // bytes that did arrive. Treating it as tampering is what
                // turned a wrong pin into an app that deleted its own model
                // and re-downloaded it on every launch, for ever.
                //
                // Nothing is lost by being lenient here: a model missing a
                // file it needs fails to load anyway, on its own terms and
                // with its own error.
                absent += 1
                continue
            }
            guard let actual = digest(of: file, using: pin.algorithm) else {
                problems.append("unreadable: \(relativePath)")
                continue
            }
            checked += 1
            if actual != pin.digest {
                // The one thing this exists to catch: a file that is present
                // and is not what we pinned.
                problems.append("changed: \(relativePath)")
            }
        }

        guard problems.isEmpty else {
            logger.error("\(model, privacy: .public) failed verification: \(problems.count) problem(s)")
            return .failed(model: model, problems: problems)
        }

        if absent > 0 {
            logger.error(
                "\(model, privacy: .public): \(absent) pinned file(s) not on disk — the manifest does not describe this layout; verified the \(checked) that are"
            )
        }
        guard checked > 0 else {
            // Every pinned path was empty. Nothing was actually verified, and
            // saying "verified" here would be a lie told in the one place
            // where the whole point is not lying about coverage.
            logger.error("\(model, privacy: .public): no pinned file was found on disk — nothing was verified")
            return .unpinned(model: model)
        }
        logger.info("\(model, privacy: .public) verified — \(checked) files")
        return .verified(fileCount: checked)
    }

    /// Verifies, and removes the model on failure.
    ///
    /// Deleting is the part that is easy to leave out and important to get
    /// right. Both libraries treat "the files are already here" as a reason to
    /// skip downloading, so a rejected model left on disk would be reused on
    /// the next launch — and would fail verification again for ever, with no
    /// way for the user to recover short of finding the cache by hand.
    /// Removing it means the next attempt re-downloads.
    @discardableResult
    public static func verifyOrDiscard(model: String, in directory: URL) throws -> Result {
        let result = verify(model: model, in: directory)
        guard case let .failed(_, problems) = result else { return result }
        try? FileManager.default.removeItem(at: directory)
        throw ModelIntegrityError.verificationFailed(model: model, problems: problems)
    }

    static func digest(of file: URL, using algorithm: Pin.Algorithm) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        switch algorithm {
        case .sha256:
            return hex(SHA256.hash(data: data))
        case .gitBlobSHA1:
            // Git hashes "blob <byte count>\0" followed by the contents. This
            // is the only digest Hugging Face publishes for files stored
            // outside LFS, so matching it means reproducing that framing
            // exactly rather than hashing the bytes alone.
            var framed = Data("blob \(data.count)\0".utf8)
            framed.append(data)
            return hex(Insecure.SHA1.hash(data: framed))
        }
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ModelIntegrityError: LocalizedError {
    case verificationFailed(model: String, problems: [String])

    public var errorDescription: String? {
        guard case let .verificationFailed(model, problems) = self else { return nil }
        let detail = problems.prefix(3).joined(separator: ", ")
        let more = problems.count > 3 ? " (+\(problems.count - 3) more)" : ""
        return Localization.coreFormat(
            "model.integrityFailed",
            fallback: """
                The downloaded speech model does not match what this version of Plainsay expects, \
                so it was discarded rather than run: %@%@. Plainsay will download it again next \
                time. If this keeps happening, check your network — %@
                """,
            detail, more, model
        )
    }
}

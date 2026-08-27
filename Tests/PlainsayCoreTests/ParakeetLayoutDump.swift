import Foundation
import Testing
@testable import PlainsayCore
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Opt-in tool, not a test of behaviour: downloads Parakeet the way the app
/// does and prints the file tree it actually produces.
///
/// Exists because pinning digests from the Hugging Face repository tree was
/// wrong — FluidAudio fetches a subset and lays it out under its own directory
/// structure, so 65 of 88 pinned paths had nothing behind them.
///
///     PLAINSAY_DUMP_PARAKEET=1 swift test --filter ParakeetLayoutDump
@Suite("Parakeet layout dump")
struct ParakeetLayoutDump {
    @Test("Dump the real download layout")
    func dump() async throws {
        guard ProcessInfo.processInfo.environment["PLAINSAY_DUMP_PARAKEET"] == "1" else { return }
        #if canImport(FluidAudio)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-parakeet-layout")
        let target = try await AsrModels.download(to: dir, version: .v3, encoderPrecision: .int8)
        print("DOWNLOADED_TO: \(target.path)")
        let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(url.path.replacingOccurrences(of: target.path + "/", with: ""))
        }
        print("FILE_COUNT: \(files.count)")
        for f in files.sorted() { print("FILE: \(f)") }
        #endif
    }
}

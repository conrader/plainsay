import Foundation
import Testing
@testable import PlainsayCore

@Suite("Voice filter settings")
@MainActor
struct VoiceFilterSettingsTests {
    @Test("Off and unenrolled by default")
    func defaultsToOff() {
        let settings = PlainsaySettings(
            defaults: UserDefaults(suiteName: "plainsay.voice.\(UUID().uuidString)")!
        )
        #expect(settings.voiceFilterEnabled == false)
        #expect(settings.voiceEmbedding == nil)
    }

    @Test("An enrolled embedding persists across relaunch")
    func embeddingPersists() {
        let suiteName = "plainsay.voice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = PlainsaySettings(defaults: defaults)

        let embedding: [Float] = (0..<256).map { Float($0) / 256 }
        settings.voiceEmbedding = embedding
        settings.voiceFilterEnabled = true

        let reloaded = PlainsaySettings(defaults: defaults)
        #expect(reloaded.voiceEmbedding == embedding)
        #expect(reloaded.voiceFilterEnabled == true)
    }
}

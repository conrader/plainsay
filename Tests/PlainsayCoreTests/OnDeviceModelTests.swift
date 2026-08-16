import Foundation
import Testing
@testable import PlainsayCore

@Suite("On-device model selection")
@MainActor
struct OnDeviceModelTests {
    private func makeSettings() -> PlainsaySettings {
        PlainsaySettings(
            defaults: UserDefaults(suiteName: "plainsay.models.\(UUID().uuidString)")!
        )
    }

    @Test("Parakeet persists as the selected local model")
    func parakeetPersists() {
        let suiteName = "plainsay.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = PlainsaySettings(defaults: defaults)

        settings.model = .parakeetTDT06BV3

        #expect(PlainsaySettings(defaults: defaults).model == .parakeetTDT06BV3)
    }

    @Test("A preference written by the old Whisper-only enum still decodes")
    func oldWhisperPreferenceStillDecodes() {
        let defaults = UserDefaults(suiteName: "plainsay.models.\(UUID().uuidString)")!
        defaults.set(
            Data(#""openai_whisper-small.en""#.utf8),
            forKey: "model"
        )

        #expect(PlainsaySettings(defaults: defaults).model == .smallEN)
    }

    @Test("The factory constructs Parakeet for the Parakeet selection")
    func factorySelectsParakeet() {
        let settings = makeSettings()
        settings.transcriptionSource = .onDevice
        settings.model = .parakeetTDT06BV3

        let engine = ProviderFactory.makeEngine(settings) { _ in }

        #expect(engine is ParakeetEngine)
    }

    @Test("Whisper selections continue to use WhisperKit")
    func factoryKeepsWhisperKit() {
        let settings = makeSettings()
        settings.transcriptionSource = .onDevice
        settings.model = .largeV3Turbo

        let engine = ProviderFactory.makeEngine(settings) { _ in }

        #expect(engine is WhisperKitEngine)
    }

    @Test("Parakeet advertises its actual local capabilities")
    func parakeetMetadata() {
        let model = OnDeviceModel.parakeetTDT06BV3

        #expect(!model.isEnglishOnly)
        #expect(!model.supportsDecoderPrompt)
        #expect(model.approximateSize.contains("475"))
    }

    @Test("No languages chosen yet recommends Parakeet")
    func recommendsParakeetByDefault() {
        #expect(OnDeviceModel.recommended(for: []) == .parakeetTDT06BV3)
    }

    @Test("Languages Parakeet actually covers still recommend Parakeet")
    func recommendsParakeetWhenCovered() {
        #expect(OnDeviceModel.recommended(for: ["pl", "en"]) == .parakeetTDT06BV3)
        #expect(OnDeviceModel.recommended(for: ["de"]) == .parakeetTDT06BV3)
        // Region-qualified codes match on the primary subtag, same as
        // SupportedLanguage.primaryCode elsewhere.
        #expect(OnDeviceModel.recommended(for: ["pt-BR"]) == .parakeetTDT06BV3)
    }

    @Test("A language outside Parakeet's coverage recommends Whisper instead")
    func recommendsWhisperWhenUncovered() {
        #expect(OnDeviceModel.recommended(for: ["ja"]) == .largeV3Turbo)
        #expect(OnDeviceModel.recommended(for: ["ar"]) == .largeV3Turbo)
        // Mixed: even one unsupported language should move the whole
        // recommendation to Whisper, since Parakeet can't cover all of them.
        #expect(OnDeviceModel.recommended(for: ["en", "hi"]) == .largeV3Turbo)
    }
}

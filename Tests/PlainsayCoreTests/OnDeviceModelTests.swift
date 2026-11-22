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

    @Test("A Polish-primary bilingual legacy install without a model keeps Whisper Turbo")
    func legacyPolishEnglishModelFallback() {
        let suite = "plainsay.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        PlainsaySettings(defaults: defaults).spokenLanguages = ["pl", "en"]
        #expect(defaults.object(forKey: "model") == nil)

        let upgraded = PlainsaySettings(defaults: defaults)
        #expect(upgraded.model == .largeV3Turbo)
        #expect(upgraded.migrateLegacyOnboardingIfNeeded(allPermissionsGranted: false))
        #expect(ProviderFactory.makeEngine(upgraded) { _ in } is WhisperKitEngine)
        #expect(PlainsaySettings(defaults: defaults).model == .largeV3Turbo)
    }

    @Test("First-run Polish-primary bilingual setup defaults to Parakeet and persists the choice")
    func firstRunPolishEnglishModelFallback() {
        let suite = "plainsay.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PlainsaySettings(defaults: defaults)
        settings.onboardingWasPresented = true
        settings.spokenLanguages = ["en", "pl"]
        #expect(PlainsaySettings(defaults: defaults).model == .largeV3Turbo)

        settings.spokenLanguages = ["pl-PL", "en-US"]
        let expected: OnDeviceModel = OnDeviceModel.parakeetTDT06BV3.isSupportedOnCurrentHardware
            ? .parakeetTDT06BV3 : .largeV3Turbo
        let resumedSetup = PlainsaySettings(defaults: defaults)
        #expect(resumedSetup.model == expected)
        #expect(defaults.object(forKey: "model") == nil)

        let recommendation = OnDeviceModel.recommended(for: resumedSetup.spokenLanguages)
        #expect(recommendation == expected)
        resumedSetup.applySetupSpeechSelection(source: .onDevice, model: recommendation)
        resumedSetup.onboardingVersion = PlainsaySettings.currentOnboardingVersion

        #expect(defaults.data(forKey: "model") != nil)
        #expect(PlainsaySettings(defaults: defaults).model == expected)
    }

    @Test("A preference written by the old Whisper-only enum still decodes")
    func oldWhisperPreferenceStillDecodes() {
        let suite = "plainsay.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = PlainsaySettings(defaults: defaults)
        setup.onboardingWasPresented = true
        setup.spokenLanguages = ["pl", "en"]
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

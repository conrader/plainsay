import Foundation
import Testing
@testable import PlainsayCore

@Suite("Setup assistant settings")
@MainActor
struct OnboardingSettingsTests {
    @Test("A new preferences store needs the current setup")
    func newInstallNeedsOnboarding() {
        let settings = makeSettings()

        #expect(settings.onboardingVersion == 0)
        #expect(settings.needsOnboarding)
    }

    @Test("Completing setup persists its version")
    func completionPersists() {
        let defaults = makeDefaults()
        let settings = PlainsaySettings(defaults: defaults)

        settings.onboardingVersion = PlainsaySettings.currentOnboardingVersion

        let relaunched = PlainsaySettings(defaults: defaults)
        #expect(relaunched.onboardingVersion == 1)
        #expect(!relaunched.needsOnboarding)
    }

    @Test("A fully-authorized legacy install skips first-run setup")
    func authorizedLegacyInstallMigrates() {
        let settings = makeSettings()

        let migrated = settings.migrateLegacyOnboardingIfNeeded(
            allPermissionsGranted: true
        )

        #expect(migrated)
        #expect(settings.onboardingVersion == PlainsaySettings.currentOnboardingVersion)
        #expect(!settings.needsOnboarding)
    }

    @Test("Missing permissions do not make a new install look migrated")
    func incompleteInstallDoesNotMigrate() {
        let settings = makeSettings()

        let migrated = settings.migrateLegacyOnboardingIfNeeded(
            allPermissionsGranted: false
        )

        #expect(!migrated)
        #expect(settings.onboardingVersion == 0)
        #expect(settings.needsOnboarding)
    }

    @Test("A configured legacy install migrates even when a permission is missing")
    func configuredLegacyInstallWithMissingPermissionMigrates() {
        let defaults = makeDefaults()
        let legacySettings = PlainsaySettings(defaults: defaults)
        legacySettings.model = .parakeetTDT06BV3

        let updatedSettings = PlainsaySettings(defaults: defaults)
        let migrated = updatedSettings.migrateLegacyOnboardingIfNeeded(
            allPermissionsGranted: false
        )

        #expect(migrated)
        #expect(updatedSettings.onboardingVersion == PlainsaySettings.currentOnboardingVersion)
        #expect(!updatedSettings.needsOnboarding)
    }

    @Test("Closing a presented setup never masquerades as a legacy install")
    func interruptedFirstRunDoesNotMigrate() {
        let defaults = makeDefaults()
        let firstRun = PlainsaySettings(defaults: defaults)
        firstRun.model = .parakeetTDT06BV3
        firstRun.onboardingWasPresented = true

        let relaunched = PlainsaySettings(defaults: defaults)

        let migrated = relaunched.migrateLegacyOnboardingIfNeeded(
            allPermissionsGranted: false
        )

        #expect(!migrated)
        #expect(relaunched.onboardingVersion == 0)
        #expect(relaunched.needsOnboarding)
    }

    @Test("Migration never rewrites an existing version")
    func existingVersionIsPreserved() {
        let settings = makeSettings()
        settings.onboardingVersion = PlainsaySettings.currentOnboardingVersion + 1

        let migrated = settings.migrateLegacyOnboardingIfNeeded(
            allPermissionsGranted: true
        )

        #expect(!migrated)
        #expect(settings.onboardingVersion == PlainsaySettings.currentOnboardingVersion + 1)
        #expect(!settings.needsOnboarding)
    }

    private func makeSettings() -> PlainsaySettings {
        PlainsaySettings(defaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "plainsay.onboarding.\(UUID().uuidString)")!
    }
}

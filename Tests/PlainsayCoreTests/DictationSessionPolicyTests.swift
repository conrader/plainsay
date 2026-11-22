import Foundation
import Testing
@testable import PlainsayCore

// Pure tests for the shared session-policy resolver (R1) and the oneshot
// string catalog entries. Pipeline tests live in PrivateDictationTests.swift.

// MARK: - 1. Policy unit (pure)

@Suite("Session policy resolver")
struct DictationSessionPolicyTests {
    @Test("Standard keeps every existing behaviour")
    func standardPolicy() {
        let policy = DictationSessionPolicy.make()
        #expect(policy == .standard)
        #expect(policy.allowsCleanup && policy.stagesRecoveryAudio && policy.writesHistory)
        #expect(policy.writesDebugAudio && policy.keepsLastDictation && policy.logsBundleIdentifiers)
        #expect(policy.honorsKeepOnClipboard && !policy.concealsPasteboard)
    }

    @Test("Private takes every Plainsay-controlled sink and hosted route away")
    func privatePolicy() {
        let policy = DictationSessionPolicy.make(privacy: .privateLocal)
        #expect(policy.privacy == .privateLocal)
        #expect(!policy.allowsCleanup && !policy.stagesRecoveryAudio && !policy.writesHistory)
        #expect(!policy.writesDebugAudio && !policy.keepsLastDictation && !policy.logsBundleIdentifiers)
        #expect(!policy.honorsKeepOnClipboard && policy.concealsPasteboard)
    }

    @Test("3.3. Replacement rules are frozen into the policy, private included")
    func replacementRulesSnapshot() {
        var defaults = DictationDefaults(replacementRules: ReplacementRuleSet(rules: [
            ReplacementRule(from: "jason", to: "JSON"),
        ]))
        let standard = DictationSessionPolicy.make(defaults: defaults)
        let local = DictationSessionPolicy.make(privacy: .privateLocal, defaults: defaults)
        defaults.replacementRules.rules.removeAll()
        defaults.replacementRules.upsert(ReplacementRule(from: "gogle", to: "Google"))
        #expect(standard.replacementRules.rules.map(\.to) == ["JSON"])
        // Local and exact: privacy keeps the rules, as it keeps the dictionary.
        #expect(local.replacementRules.rules.map(\.to) == ["JSON"])
        #expect(DictationSessionPolicy.standard.replacementRules.rules.isEmpty)
    }

    @Test("Refusal depends on the prepared engine, the configured source and readiness")
    func refusal() {
        func refusal(_ prepared: TranscriptionSource?, _ configured: TranscriptionSource = .onDevice,
                     _ state: SpeechModelLoadState = .ready) -> PrivateDictationRefusal? {
            DictationSessionPolicy.privateRefusal(preparedSource: prepared, configuredSource: configured, modelState: state)
        }
        #expect(refusal(.onDevice) == nil)
        #expect(refusal(.cloud) == .notOnDevice)
        #expect(refusal(.remote) == .notOnDevice)
        #expect(refusal(nil) == .notOnDevice)
        // Cloud reports `.ready` at once, so readiness alone must never pass.
        #expect(refusal(.cloud, .cloud, .ready) == .notOnDevice)
        // A Speech change whose reload is still queued.
        #expect(refusal(.onDevice, .cloud) == .notOnDevice)
        #expect(refusal(.onDevice, .onDevice, .loading(progress: nil)) == .modelNotReady)
        #expect(refusal(.onDevice, .onDevice, .downloading(progress: 0.5)) == .modelNotReady)
        #expect(refusal(.onDevice, .onDevice, .failed("x")) == .modelNotReady)
        #expect(refusal(.onDevice, .onDevice, .idle) == .modelNotReady)
    }

    @Test("10. Debug audio is never written for a private session, even with the diagnostic on")
    func debugAudioGate() {
        let defaults = UserDefaults(suiteName: "plainsay.private.debug.\(UUID().uuidString)")!
        defaults.set(true, forKey: VoiceFilterDebugAudio.defaultsKey)
        #expect(!VoiceFilterDebugAudio.shouldSave(policy: .make(privacy: .privateLocal), defaults: defaults))
        #expect(VoiceFilterDebugAudio.shouldSave(policy: .standard, defaults: defaults))
        defaults.set(false, forKey: VoiceFilterDebugAudio.defaultsKey)
        #expect(!VoiceFilterDebugAudio.shouldSave(policy: .standard, defaults: defaults))
    }

    @Test("The paste log line names no app when redacted, including the report's frontmost app")
    func pasteLogRedaction() {
        let report = PasteTargetReport(
            decision: .paste, reason: "targetInFront", reactivationAttempted: false,
            frontmostBundleIdentifier: "com.example.secret"
        )
        let line = PasteDecisionLog.message(
            outcome: .inserted, report: report, targetBundleIdentifier: "com.example.secret",
            frontmostBundleIdentifier: "com.example.other", keepOnClipboardSetting: false,
            redactsBundleIdentifiers: true
        )
        #expect(line == "paste decision=paste reason=targetInFront target=redacted reactivationAttempted=false frontmost=redacted clipboardKept=false")
        #expect(!line.contains("com.example"))
    }
}

// MARK: - 13. Strings

@Suite("Private dictation strings")
struct PrivateDictationStringTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func catalog(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(relative))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func value(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test("Every new key has English and Polish in the catalog its code reads")
    func catalogs() throws {
        let app = try catalog("Sources/PlainsayApp/Resources/Localizable.xcstrings")
        let core = try catalog("Sources/PlainsayCore/Resources/CoreLocalizable.xcstrings")
        let appKeys = [
            "menu.private.arm", "menu.private.armed", "menu.private.copy", "menu.a11y.privateArmed",
            "menu.correctLast", "hud.label.private", "hud.a11y.private", "settings.private.title",
            "settings.private.explainer", "settings.private.consumption", "settings.private.armNow",
        ]
        let coreKeys = [
            "menu.private.needsOnDevice", "menu.private.modelNotReady", "coordinator.private.refused",
            "coordinator.private.onClipboard", "coordinator.private.stillArmed", "coordinator.private.blocksEditing",
        ]
        for key in appKeys {
            #expect(value(app, key, "en")?.isEmpty == false, "\(key) en")
            #expect(value(app, key, "pl")?.isEmpty == false, "\(key) pl")
        }
        for key in coreKeys {
            #expect(value(core, key, "en")?.isEmpty == false, "\(key) en")
            #expect(value(core, key, "pl")?.isEmpty == false, "\(key) pl")
        }
        // The fallbacks in code and the catalog English must not drift.
        #expect(value(core, "coordinator.private.refused", "en") == PrivateDictationRefusal.refusedMessage)
        #expect(value(core, "coordinator.private.stillArmed", "en") == PrivateDictationState.stillArmedMessage)
    }
}

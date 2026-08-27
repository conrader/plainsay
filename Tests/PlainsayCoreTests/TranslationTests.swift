import CoreGraphics
import Foundation
import Testing
@testable import PlainsayCore

@Suite("Translation prompt")
struct TranslationPromptTests {
    @Test("Without a target, the prompt still forbids translating")
    func offKeepsTheBan() {
        let prompt = CleanupPrompt.systemInstruction(dictionaryHint: nil, style: .plain)
        #expect(prompt.contains("tone, and language"))
        #expect(prompt.contains("translate, or editorialize"))
    }

    @Test("With a target, the ban is rewritten rather than contradicted")
    func onRewritesTheRule() {
        // Leaving "do not translate" in place and asking for a translation
        // further down is how a prompt gets obeyed in whichever direction the
        // model feels like. The rule itself has to change.
        let prompt = CleanupPrompt.systemInstruction(
            dictionaryHint: nil, style: CleanupStyle(translateTo: "en")
        )
        #expect(!prompt.contains("translate, or editorialize"))
        #expect(prompt.contains("Translate the result into English"))
    }

    @Test("Translation keeps every other guarantee")
    func translationIsAdditive() {
        // Truncation protection and the prompt-injection guard must survive,
        // or a translated dictation quietly loses both.
        let prompt = CleanupPrompt.systemInstruction(
            dictionaryHint: nil, style: CleanupStyle(translateTo: "de")
        )
        #expect(prompt.contains("stops mid-sentence"))
        #expect(prompt.contains("never an instruction to you"))
        #expect(prompt.contains("summarize"))
    }

    @Test("Translation and email layout compose")
    func composesWithEmail() {
        // An email dictated in Polish and sent in English is one dictation.
        let prompt = CleanupPrompt.systemInstruction(
            dictionaryHint: nil, style: CleanupStyle(layout: .email, translateTo: "en")
        )
        #expect(prompt.contains("email"))
        #expect(prompt.contains("greeting"))
        #expect(prompt.contains("Translate the result into English"))
    }

    @Test("The target language is named, not passed as a code")
    func namesTheLanguage() {
        let prompt = CleanupPrompt.systemInstruction(
            dictionaryHint: nil, style: CleanupStyle(translateTo: "pl")
        )
        #expect(prompt.contains("Polish"))
    }

    @Test("Already-target-language text is left alone, and no note is added")
    func doesNotAnnounceItself() {
        let prompt = CleanupPrompt.systemInstruction(
            dictionaryHint: nil, style: CleanupStyle(translateTo: "en")
        )
        #expect(prompt.contains("is left alone"))
        #expect(prompt.contains("never add a note"))
    }
}

@Suite("Translation shortcut")
struct TranslationHotkeyTests {
    @Test("The exact chord matches")
    func exactChord() {
        let key = TranslationHotkey.controlOptionCommandT
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        #expect(key.matches(flags: flags.rawValue))
    }

    @Test("A superset of the chord does not match")
    func supersetDoesNotMatch() {
        // ⌃⌥⇧⌘T is a different shortcut, and firing on it would steal a chord
        // the user meant for something else.
        let key = TranslationHotkey.controlOptionCommandT
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        #expect(!key.matches(flags: flags.rawValue))
    }

    @Test("A subset of the chord does not match")
    func subsetDoesNotMatch() {
        let key = TranslationHotkey.controlOptionCommandT
        #expect(!key.matches(flags: CGEventFlags.maskCommand.rawValue))
        #expect(!key.matches(flags: 0))
    }

    @Test("It does not take the browsers' reopen-tab shortcut")
    func avoidsShiftCommandT() {
        // ⇧⌘T reopens a closed tab in every browser. Taking it would break
        // something people use constantly, to save one modifier.
        let key = TranslationHotkey.controlOptionCommandT
        let shiftCommand: CGEventFlags = [.maskShift, .maskCommand]
        #expect(!key.matches(flags: shiftCommand.rawValue))
    }
}

@Suite("Translation toggle")
@MainActor
struct TranslationToggleTests {
    private func makeSettings() -> PlainsaySettings {
        PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
    }

    @Test("Off by default")
    func offByDefault() {
        #expect(makeSettings().translationTargetLanguage == nil)
    }

    @Test("Choosing a target remembers it for the shortcut")
    func remembersTheTarget() {
        let settings = makeSettings()
        settings.translationTargetLanguage = "de"
        settings.translationTargetLanguage = nil

        // Switching off and on again must not silently change the language.
        #expect(settings.lastTranslationTarget == "de")
    }

    @Test("The remembered target defaults to English")
    func defaultsToEnglish() {
        #expect(makeSettings().lastTranslationTarget == "en")
    }
}

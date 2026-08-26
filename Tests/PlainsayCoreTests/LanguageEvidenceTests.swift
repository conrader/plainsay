import Foundation
import Testing
@testable import PlainsayCore

/// From a real report: "unieważnij", said in Polish by someone whose languages
/// are English and Polish, came back as Czech.
@Suite("Wrong-language detection")
struct LanguageEvidenceTests {
    @Test("Czech output is caught for a Polish and English speaker")
    func theReportedCase() {
        // "neplatné" — Czech for invalid, with the ě that Polish never uses.
        #expect(LanguageEvidence.isOutsideSpokenLanguages("neplatné, zrušit to hned", spokenLanguages: ["en", "pl"]) == false,
                "no exclusive letter here — é is not decisive")
        #expect(LanguageEvidence.isOutsideSpokenLanguages("neplatné, běž tam", spokenLanguages: ["en", "pl"]))
    }

    @Test("Polish is not flagged when the list starts with English")
    func listOrderDoesNotMatter() {
        // The defect this was found through: the engine was told only the
        // *first* language, so a Polish word from someone listed as
        // ["en", "pl"] looked foreign. It is exactly what they said.
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("unieważnij to zlecenie", spokenLanguages: ["en", "pl"]))
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("unieważnij to zlecenie", spokenLanguages: ["pl", "en"]))
    }

    @Test("Letters shared between languages are never evidence")
    func sharedLettersProveNothing() {
        // š and č belong to Czech, Slovak, Croatian and Slovenian alike. A
        // detector that treated them as Czech would fire on half of central
        // Europe, and a false positive is paid for by the speaker.
        #expect(LanguageEvidence.languages(in: "čas šest").isEmpty)
    }

    @Test("Exclusive letters identify their language")
    func exclusiveLetters() {
        #expect(LanguageEvidence.languages(in: "łódź") == ["pl"])
        #expect(LanguageEvidence.languages(in: "řeka") == ["cs"])
        #expect(LanguageEvidence.languages(in: "tűz") == ["hu"])
        #expect(LanguageEvidence.languages(in: "știre") == ["ro"])
    }

    @Test("Plain English and empty text are never flagged")
    func noEvidenceIsNotEvidence() {
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("cancel that order", spokenLanguages: ["en", "pl"]))
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("", spokenLanguages: ["en", "pl"]))
    }

    @Test("An empty language list means full auto-detect, so nothing is foreign")
    func emptyListNeverFlags() {
        // Nothing chosen means the speaker asked for automatic multilingual
        // decoding. Flagging there would fight the setting.
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("řeka", spokenLanguages: []))
    }

    @Test("A language on the list is never foreign, however unusual its letters")
    func listedLanguagesPass() {
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("řeka", spokenLanguages: ["cs"]))
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("łódź", spokenLanguages: ["pl", "en"]))
    }

    @Test("Region suffixes on codes still match")
    func regionSuffixes() {
        #expect(!LanguageEvidence.isOutsideSpokenLanguages("łódź", spokenLanguages: ["en-US", "pl-PL"]))
    }
}

import FluidAudio
import Foundation

extension OnDeviceModel {
    /// Which on-device model actually fits what someone speaks.
    ///
    /// Parakeet's real coverage is FluidAudio's `Language` list — every
    /// European language it can transcribe, not just the "Polish + English"
    /// the model's own display name leads with for marketing reasons. A
    /// spoken language outside that list (Japanese, Arabic, Hindi, anything
    /// non-European) needs Whisper's much broader 99-language set instead,
    /// even though Whisper is the larger download.
    ///
    /// An empty `spokenLanguages` (nothing chosen yet, or full auto-detect)
    /// defaults to Parakeet — smaller, faster, and it's what most people
    /// setting up for the first time actually want.
    public static func recommended(for spokenLanguages: [String]) -> OnDeviceModel {
        guard parakeetTDT06BV3.isSupportedOnCurrentHardware else {
            // Apple silicon only; Intel Macs never see Parakeet as an option.
            return largeV3Turbo
        }
        guard !spokenLanguages.isEmpty else {
            return parakeetTDT06BV3
        }

        let parakeetCodes = Set(Language.allCases.map(\.rawValue))
        let coveredByParakeet = spokenLanguages.allSatisfy { code in
            parakeetCodes.contains(SupportedLanguage.primaryCode(code))
        }
        return coveredByParakeet ? parakeetTDT06BV3 : largeV3Turbo
    }
}

import Foundation
import Testing

@testable import PlainsayCore

/// conrader/plainsay#46 asked for the two numbers a first run is missing: how
/// big the download is, and how long the preparation that follows it takes.
/// The size is known for every model. The duration is not — so only a model
/// whose preparation has actually been timed is allowed to claim one.
@Suite("First-run model expectations")
struct FirstRunEstimateTests {
    @Test("The size of the download is worth saying while it is downloading")
    func sizeShownWhileDownloading() {
        let watchdog = SpeechModelLoadWatchdog(
            state: .downloading(progress: 0.4), timing: nil, now: Date()
        )
        #expect(watchdog.showsDownloadSize)
    }

    @Test("Once downloaded, its size is no longer what the user is waiting on")
    func sizeHiddenWhilePreparing() {
        let watchdog = SpeechModelLoadWatchdog(state: .loading(progress: nil), timing: nil, now: Date())
        #expect(!watchdog.showsDownloadSize)
    }

    @Test("A model whose preparation has been timed states a duration")
    func timedModelClaimsDuration() {
        #expect(OnDeviceModel.parakeetTDT06BV3.approximatePreparationTime != nil)
    }

    @Test("A model nobody has timed claims nothing rather than guessing")
    func untimedModelStaysSilent() {
        #expect(OnDeviceModel.largeV3Turbo.approximatePreparationTime == nil)
        #expect(OnDeviceModel.baseEN.approximatePreparationTime == nil)
    }
}

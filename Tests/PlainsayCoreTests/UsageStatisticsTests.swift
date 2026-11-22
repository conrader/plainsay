import Foundation
import Testing
@testable import PlainsayCore

@MainActor
struct UsageStatisticsTests {
    @Test func consentIsOffByDefaultAndPersistsAnExplicitChoice() {
        let suite = "plainsay.tests.usage.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PlainsaySettings(defaults: defaults)
        #expect(!settings.shareAnonymousUsageStatistics)
        #expect(settings.usageStatisticsConsentRevision == 0)
        var changes: [Int] = []
        settings.onUsageStatisticsChanged = { changes.append($0) }
        settings.shareAnonymousUsageStatistics = true
        settings.shareAnonymousUsageStatistics = true
        #expect(PlainsaySettings(defaults: defaults).shareAnonymousUsageStatistics)
        settings.shareAnonymousUsageStatistics = false
        #expect(!PlainsaySettings(defaults: defaults).shareAnonymousUsageStatistics)
        #expect(changes == [1, 2])
    }

    @Test func noCollectionWhileOffOrForPrivateAndCorrectionCaptures() {
        let fixture = Fixture()
        let client = fixture.client()
        client.record(client.beginDictation(isPrivate: false, isCorrection: false), seconds: 5)
        client.updateConsent(1, automaticallyUpload: false)
        for consent in [
            client.beginDictation(isPrivate: true, isCorrection: false),
            client.beginDictation(isPrivate: false, isCorrection: true),
        ] {
            #expect(consent == nil)
            client.record(consent, seconds: 5, failures: [.transcription])
        }
        fixture.advance(days: 1)
        #expect(client.flush(isOnline: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func closedDaysBatchOncePerUtcDayAfterOfflineRestart() async throws {
        let fixture = Fixture()
        let first = fixture.client()
        first.updateConsent(1, automaticallyUpload: false)
        first.record(first.beginDictation(isPrivate: false, isCorrection: false), seconds: 10)
        #expect(first.flush(isOnline: true) == nil)
        fixture.advance(days: 1)
        first.record(first.beginDictation(isPrivate: false, isCorrection: false), seconds: 10)
        #expect(first.flush(isOnline: false) == nil)
        fixture.advance(days: 1)

        let restarted = fixture.client()
        restarted.updateConsent(1, automaticallyUpload: false)
        let upload = try #require(restarted.flush(isOnline: true))
        await upload.value
        #expect(restarted.flush(isOnline: true) == nil)
        let days = try fixture.reports()
        #expect(days.compactMap { $0["day"] as? String } == ["2026-11-16", "2026-11-17"])
        #expect(days.compactMap { $0["weekly_active"] as? Bool } == [true, false])

        let onceMore = fixture.client()
        onceMore.updateConsent(1, automaticallyUpload: false)
        #expect(onceMore.flush(isOnline: true) == nil)
        #expect(fixture.payloads.count == 1)
    }

    @Test func startsNewWeeklyContributionOnMondayAndExpiresOldDays() async throws {
        let fixture = Fixture()
        let client = fixture.client()
        client.updateConsent(1, automaticallyUpload: false)
        let consent = client.beginDictation(isPrivate: false, isCorrection: false)
        client.record(consent, seconds: 6)
        fixture.advance(days: 6)
        client.record(consent, seconds: 6)
        fixture.advance(days: 1)
        client.record(consent, seconds: 6)
        fixture.advance(days: 1)

        let upload = try #require(client.flush(isOnline: true))
        await upload.value
        let days = try fixture.reports()
        #expect(days.compactMap { $0["day"] as? String } == ["2026-11-22", "2026-11-23"])
        #expect(days.compactMap { $0["weekly_active"] as? Bool } == [true, true])
    }

    @Test func encodesOnlyAllowedFieldsAndBuckets() async throws {
        let fixture = Fixture()
        let client = fixture.client(appVersion: "0.2.38")
        client.updateConsent(1, automaticallyUpload: false)
        let consent = client.beginDictation(isPrivate: false, isCorrection: false)
        for _ in 0..<4 {
            client.record(consent, seconds: 15, mode: .local, attemptedPolishing: true, language: "pl-PL")
        }
        client.record(consent, seconds: 5, mode: .cloud, language: "unexpected/path", failures: [.transcription])
        client.record(consent, failures: [.recording])
        fixture.advance(days: 1)

        let upload = try #require(client.flush(isOnline: true))
        await upload.value
        let report = try #require(try fixture.reports().first)
        #expect(Set(report.keys) == [
            "day", "weekly_active", "app_version", "macos_version", "dictations",
            "audio_minutes", "modes", "languages", "failures",
        ])
        #expect(report["app_version"] as? String == "0.2.38")
        #expect(report["macos_version"] as? String == "15.7")
        #expect(report["dictations"] as? String == "5-19")
        #expect(report["audio_minutes"] as? String == "1-<5")
        #expect(report["modes"] as? [String: String] == ["local": "1-4", "cloud": "1-4", "polishing": "1-4"])
        #expect(report["languages"] as? [String] == ["auto", "pl"])
        #expect(report["failures"] as? [String: Int] == ["transcription": 1, "recording": 1])
    }

    @Test func withdrawalCancelsQueuedSendAndDiscardsOldConsent() async throws {
        let fixture = Fixture()
        let client = fixture.client()
        client.updateConsent(1, automaticallyUpload: false)
        let old = client.beginDictation(isPrivate: false, isCorrection: false)
        client.record(old, seconds: 30)
        let staleFile = try Data(contentsOf: fixture.file)
        fixture.advance(days: 1)

        let upload = try #require(client.flush(isOnline: true))
        client.updateConsent(2, automaticallyUpload: false)
        #expect(upload.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        await upload.value
        #expect(fixture.payloads.isEmpty)

        // Simulate withdrawal on a filesystem that could not delete the old file.
        try staleFile.write(to: fixture.file)
        let restarted = fixture.client()
        restarted.updateConsent(3, automaticallyUpload: false)
        restarted.record(old, seconds: 30)
        fixture.advance(days: 1)
        #expect(restarted.flush(isOnline: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func capsDailyFailureCountsAndSendsFailureOnlyDays() async throws {
        let fixture = Fixture()
        let client = fixture.client(appVersion: "/private/path")
        client.updateConsent(1, automaticallyUpload: false)
        let consent = client.beginDictation(isPrivate: false, isCorrection: false)
        for _ in 0..<101 {
            client.record(consent, failures: [.permission])
        }
        fixture.advance(days: 1)
        let upload = try #require(client.flush(isOnline: true))
        await upload.value
        let report = try #require(try fixture.reports().first)
        #expect(report["app_version"] as? String == "unknown")
        #expect(report["failures"] as? [String: Int] == ["permission": 100])
        #expect(report["dictations"] as? String == "0")
        #expect(report["audio_minutes"] as? String == "0")
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var file: URL { directory.appendingPathComponent("days.json") }
        var now = ISO8601DateFormatter().date(from: "2026-11-16T23:59:00Z")!
        var payloads: [Data] = []

        deinit { try? FileManager.default.removeItem(at: directory) }

        func client(appVersion: String = "0.2.38") -> UsageStatistics {
            UsageStatistics(file: file, appVersion: appVersion, macOSVersion: "15.7", now: { self.now }) {
                self.payloads.append($0)
            }
        }

        func advance(days: Int) {
            now.addTimeInterval(Double(days) * 86_400)
        }

        func reports() throws -> [[String: Any]] {
            let payload = try #require(payloads.last)
            let envelope = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(Set(envelope.keys) == ["schema", "days"])
            #expect(envelope["schema"] as? Int == 1)
            return try #require(envelope["days"] as? [[String: Any]])
        }
    }
}

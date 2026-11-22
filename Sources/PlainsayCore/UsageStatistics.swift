import Foundation
import Network

/// Optional, identifier-free usage counters. Only closed UTC days go on the wire.
@MainActor
public final class UsageStatistics {
    enum Mode: String { case local, cloud, remote }
    enum Failure: String { case model, permission, recording, transcription, polishing, insertion }

    private struct Day: Codable {
        let appVersion: String
        let macOSVersion: String
        var dictations = 0
        var audioSeconds: Double = 0
        var modes: [String: Int] = [:]
        var languages: Set<String> = []
        var failures: [String: Int] = [:]
    }

    private struct State: Codable {
        var consentRevision = 0
        var days: [Int: Day] = [:]
        var reportedWeeks: Set<Int> = []
        var lastUploadDay: Int?
    }

    private struct Batch: Encodable {
        let schema = 1
        let days: [Report]
    }

    private struct Report: Encodable {
        let day: String
        let weeklyActive: Bool
        let appVersion: String
        let macosVersion: String
        let dictations: String
        let audioMinutes: String
        let modes: [String: String]
        let languages: [String]
        let failures: [String: Int]
    }

    private let file: URL
    private let now: () -> Date
    private let appVersion: String
    private let macOSVersion: String
    private let send: @MainActor (Data) async -> Void
    private var state = State()
    private var consentRevision = 0
    private var enabled: Bool { consentRevision % 2 == 1 }
    private var monitor: NWPathMonitor?
    private var pollTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.init(
            file: support.appendingPathComponent("Plainsay/UsageStatistics/days.json"),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion)",
            now: { Date() },
            send: { data in await Self.post(data) }
        )
    }

    init(
        file: URL,
        appVersion: String,
        macOSVersion: String,
        now: @escaping () -> Date,
        send: @escaping @MainActor (Data) async -> Void
    ) {
        self.file = file
        self.appVersion = Self.validVersion(appVersion, components: 2...3) ? appVersion : "unknown"
        self.macOSVersion = Self.validVersion(macOSVersion, components: 2...2) ? macOSVersion : "unknown"
        self.now = now
        self.send = send
    }

    public func updateConsent(_ revision: Int) {
        updateConsent(revision, automaticallyUpload: true)
    }

    func updateConsent(_ revision: Int, automaticallyUpload: Bool) {
        if enabled && consentRevision == revision { return }
        consentRevision = revision
        pollTask?.cancel()
        pollTask = nil
        uploadTask?.cancel()
        uploadTask = nil
        monitor?.cancel()
        monitor = nil
        state = State(consentRevision: revision)

        if enabled, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(State.self, from: data),
           saved.consentRevision == revision {
            state = saved
            if prune(today: utcDay()) { _ = save(state) }
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        if enabled && automaticallyUpload { startPolling() }
    }

    private func startPolling() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "app.plainsay.usage-statistics"))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.flush(isOnline: monitor.currentPath.status == .satisfied)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// A capture begun before consent, or before a withdrawal, cannot contribute.
    func beginDictation(isPrivate: Bool, isCorrection: Bool) -> Int? {
        guard enabled, !isPrivate, !isCorrection else { return nil }
        return consentRevision
    }

    func record(
        _ generation: Int?, seconds: Double = 0, mode: Mode? = nil,
        attemptedPolishing: Bool = false, language: String? = nil, failures: [Failure] = []
    ) {
        guard enabled, generation == consentRevision, seconds > 0 || !failures.isEmpty else { return }
        let today = utcDay()
        _ = prune(today: today)
        var day = state.days[today] ?? Day(appVersion: appVersion, macOSVersion: macOSVersion)
        if seconds > 0 {
            day.dictations = min(100, day.dictations + 1)
            day.audioSeconds = min(3_600, day.audioSeconds + seconds)
            if let mode { Self.increment(mode.rawValue, in: &day.modes) }
            if attemptedPolishing { Self.increment("polishing", in: &day.modes) }
            let code = language.map(SupportedLanguage.primaryCode)
            day.languages.insert(code.flatMap { Self.languageCodes.contains($0) ? $0 : nil } ?? "auto")
        }
        for failure in failures {
            Self.increment(failure.rawValue, in: &day.failures)
        }
        state.days[today] = day
        _ = save(state)
    }

    /// Reserve the batch on disk before sending. Neither the server nor a
    /// retry needs an identifier, and an ambiguous result cannot be replayed.
    @discardableResult
    func flush(isOnline: Bool) -> Task<Void, Never>? {
        guard enabled else { return nil }
        let today = utcDay()
        if prune(today: today) { _ = save(state) }
        guard isOnline, uploadTask == nil, today > (state.lastUploadDay ?? Int.min) else { return nil }
        let closedDays = state.days.keys.filter { $0 < today }.sorted()
        guard !closedDays.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var next = state
        let reports = closedDays.compactMap { day -> Report? in
            guard let counters = next.days.removeValue(forKey: day) else { return nil }
            // Unix day zero was a Thursday. ISO weeks begin on Monday.
            let week = day - ((day + 3) % 7 + 7) % 7
            return Report(
                day: formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86_400)),
                weeklyActive: next.reportedWeeks.insert(week).inserted,
                appVersion: counters.appVersion,
                macosVersion: counters.macOSVersion,
                dictations: Self.dictationBucket(counters.dictations),
                audioMinutes: Self.audioBucket(counters.audioSeconds),
                modes: counters.modes.mapValues(Self.dictationBucket),
                languages: counters.languages.sorted(),
                failures: counters.failures
            )
        }
        next.lastUploadDay = today
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(Batch(days: reports)), save(next) else { return nil }
        state = next
        let revision = consentRevision
        let task = Task { [weak self, send] in
            guard !Task.isCancelled else { return }
            await send(body)
            if self?.consentRevision == revision { self?.uploadTask = nil }
        }
        uploadTask = task
        return task
    }

    private func utcDay() -> Int {
        Int(floor(now().timeIntervalSince1970 / 86_400))
    }

    @discardableResult
    private func prune(today: Int) -> Bool {
        let count = state.days.count + state.reportedWeeks.count
        state.days = state.days.filter { (today - 7...today).contains($0.key) }
        state.reportedWeeks = state.reportedWeeks.filter { $0 >= today - 13 }
        return count != state.days.count + state.reportedWeeks.count
    }

    private func save(_ value: State) -> Bool {
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            guard PrivateFiles.restrictToOwner(folder, isDirectory: true),
                  PrivateFiles.excludeFromBackup(folder) else { return false }
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            return PrivateFiles.protectWrittenFile(file)
        } catch {
            return false
        }
    }

    private static let languageCodes = Set(SupportedLanguage.all.map(\.code))

    private static func validVersion(_ value: String, components: ClosedRange<Int>) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.contains(parts.count) && parts.allSatisfy {
            (1...3).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private static func increment(_ key: String, in counts: inout [String: Int]) {
        counts[key] = min(100, counts[key, default: 0] + 1)
    }

    private static func dictationBucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1...4: "1-4"
        case 5...19: "5-19"
        case 20...49: "20-49"
        case 50...99: "50-99"
        default: "100+"
        }
    }

    private static func audioBucket(_ seconds: Double) -> String {
        switch seconds {
        case 0: "0"
        case ..<60: "<1"
        case ..<300: "1-<5"
        case ..<900: "5-<15"
        case ..<3_600: "15-<60"
        default: "60+"
        }
    }

    private static func post(_ data: Data) async {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: UsageStatisticsTransport(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://api.plainsay.app/v1/usage-statistics")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Plainsay-Usage/1", forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        _ = try? await session.data(for: request)
    }
}

private final class UsageStatisticsTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

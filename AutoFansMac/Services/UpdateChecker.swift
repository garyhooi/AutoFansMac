//
//  UpdateChecker.swift
//  AutoFansMac
//
//  "Is there a newer release?" — once a day on its own, and whenever the user asks.
//
//  The check is deliberately the smallest thing that can answer that question: one
//  unauthenticated GET against the public releases API, nothing sent about this Mac.
//  Every run is written into the diagnostics ring, so "when did it last phone home and
//  what came back?" is a question the user can answer from the app itself.
//

import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        /// The repository has no published releases yet.
        case noReleases
        /// Running the newest release there is; carries the version GitHub reports.
        case upToDate(String)
        case available(ReleaseInfo)
        case failed(String)

        var isChecking: Bool { self == .checking }
    }

    @Published private(set) var state: State = .idle

    /// Called once per newly seen version, for the *automatic* check only: the manual one
    /// reports through `state`, and a banner the user just asked for is noise.
    var onUpdateAvailable: ((ReleaseInfo) -> Void)?

    /// How long between automatic checks. Enforced across launches as well as inside one:
    /// a menu-bar app can run for weeks, and a laptop can be reopened all day.
    static let automaticInterval: TimeInterval = 24 * 60 * 60
    /// How often the app asks whether the interval above has elapsed.
    static let dueCheckInterval: TimeInterval = 6 * 60 * 60
    /// Startup is busy with the SMC and the helper; touch the network a moment later.
    static let launchDelay: TimeInterval = 10

    private let log: DiagnosticsLog
    private let currentVersion: String
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetchLatest: () async throws -> ReleaseInfo?

    private var timer: DispatchSourceTimer?
    /// At most one announcement per version per run.
    private var announcedVersion: String?

    init(
        log: DiagnosticsLog,
        currentVersion: String = Bundle.main.shortVersion,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchLatest: @escaping () async throws -> ReleaseInfo? = { try await GitHubReleases().latest() }
    ) {
        self.log = log
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetchLatest = fetchLatest
    }

    // MARK: - Schedule

    /// Starts the automatic schedule: one check shortly after launch, then daily.
    func start() {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.dueCheckInterval, repeating: Self.dueCheckInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.checkIfDue() }
        }
        timer.resume()
        self.timer = timer

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.launchDelay * 1_000_000_000))
            await checkIfDue()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The automatic path: honours the preference and the once-a-day interval.
    func checkIfDue() async {
        guard automaticChecksEnabled else {
            log.info("updates", "automatic update check is off")
            return
        }
        if let last = defaults.object(forKey: SettingsKey.lastUpdateCheckAt) as? Date,
           now().timeIntervalSince(last) < Self.automaticInterval {
            return
        }
        await performCheck(announce: true)
    }

    /// The manual path — "Check Now" always goes, whatever the schedule says.
    func check() async {
        await performCheck(announce: false)
    }

    private var automaticChecksEnabled: Bool {
        defaults.object(forKey: SettingsKey.checkForUpdatesAutomatically) as? Bool ?? true
    }

    // MARK: - The check

    private func performCheck(announce: Bool) async {
        guard !state.isChecking else { return }
        state = .checking
        log.info("updates", "checking \(GitHubReleases.latestReleaseURL.absoluteString) "
                 + "for a release newer than \(currentVersion)")

        do {
            guard let release = try await fetchLatest() else {
                state = .noReleases
                recordSuccessfulCheck()
                log.info("updates", "the repository has no releases yet")
                return
            }

            recordSuccessfulCheck()
            if release.isNewer(than: currentVersion) {
                state = .available(release)
                log.info("updates", "release \(release.version) is available")
                if announce, announcedVersion != release.version {
                    announcedVersion = release.version
                    onUpdateAvailable?(release)
                }
            } else {
                state = .upToDate(release.version)
                log.info("updates", "up to date at \(currentVersion); the latest release is \(release.version)")
            }
        } catch {
            state = .failed(Self.describe(error))
            log.warning("updates", "update check failed: \(Self.describe(error))")
        }
    }

    /// Only a definitive answer starts the 24 h clock. An offline laptop should retry on the
    /// next due-check, not wait a day for a check that never happened.
    private func recordSuccessfulCheck() {
        defaults.set(now(), forKey: SettingsKey.lastUpdateCheckAt)
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No internet connection"
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "GitHub did not answer in time"
        }
        return error.localizedDescription
    }
}

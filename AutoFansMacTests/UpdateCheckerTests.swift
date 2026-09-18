//
//  UpdateCheckerTests.swift
//  AutoFansMacTests
//
//  The update check is the only code in the app that talks to anything, so it is also the
//  only code that has to behave when the network is down, rate limited, or answering
//  something unexpected. Nothing here touches the network: the fetch is injected, and the
//  payload decoding is fed from a fixture.
//

import XCTest
@testable import AutoFansMac

@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Harness

    /// A throwaway defaults suite: these tests must not read or write the real preferences.
    private func makeDefaults() -> UserDefaults {
        let name = "com.autofansmac.tests.updates.(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeChecker(
        latest: ReleaseInfo? = nil,
        failure: Error? = nil,
        current: String = "1.0.0",
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        onFetch: @escaping () -> Void = {}
    ) -> UpdateChecker {
        UpdateChecker(
            log: DiagnosticsLog(),
            currentVersion: current,
            defaults: defaults,
            now: now,
            fetchLatest: {
                onFetch()
                if let failure { throw failure }
                return latest
            }
        )
    }

    private func release(_ version: String, diskImage: Bool = true) -> ReleaseInfo {
        ReleaseInfo(
            version: version,
            pageURL: URL(string: "https://github.com/garyhooi/AutoFansMac/releases/tag/v\(version)")!,
            downloadURL: diskImage
                ? URL(string: "https://github.com/garyhooi/AutoFansMac/releases/download/v\(version)/AutoFansMac-\(version).dmg")
                : nil
        )
    }

    private func version(_ raw: String) throws -> SemanticVersion {
        try XCTUnwrap(SemanticVersion(raw), "\(raw) should parse as a version")
    }

    // MARK: - Version comparison

    /// As strings "1.9.9" is *greater* than "1.10.0". The update check must not fall for that.
    func testVersionsCompareNumericallyNotLexically() throws {
        let newer = try version("1.10.0")
        let older = try version("1.9.9")
        XCTAssertTrue(newer > older)

        XCTAssertTrue(try version("1.0.1") > version("1.0.0"))
        XCTAssertTrue(try version("2.0") > version("1.99.99"))
    }

    /// A tag and the app's own `MARKETING_VERSION` have no reason to use the same number of
    /// components, so missing ones read as zero.
    func testVersionPaddingAndUnreadableTags() throws {
        XCTAssertEqual(try version("v1.0.0"), try version("1.0"))
        XCTAssertEqual(try version("1.2"), try version("v1.2.0"))
        XCTAssertTrue(try version("1.2.1") > version("1.2"))

        // A suffix is a pre-release label; the releases endpoint never returns one anyway.
        XCTAssertEqual(try version("1.0.1-rc1"), try version("1.0.1"))

        XCTAssertNil(SemanticVersion("beta"))
        XCTAssertNil(SemanticVersion(""))
    }

    /// An unknown numbering scheme must not read as "you are already up to date".
    func testUnreadableTagsFallBackToInequality() {
        let release = release("build-2026-09")
        XCTAssertTrue(release.isNewer(than: "1.0.0"))
        XCTAssertFalse(release.isNewer(than: "build-2026-09"))
    }

    // MARK: - Decoding

    func testReleaseDecodingReadsTheTagAndPrefersTheDiskImage() throws {
        let payload = """
        {
          "tag_name": "v1.0.1",
          "html_url": "https://github.com/garyhooi/AutoFansMac/releases/tag/v1.0.1",
          "assets": [
            { "name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt" },
            { "name": "AutoFansMac-1.0.1-unsigned.dmg", "browser_download_url": "https://example.com/AutoFansMac-1.0.1-unsigned.dmg" }
          ]
        }
        """.data(using: .utf8)!

        let release = try GitHubReleases.decode(payload)
        XCTAssertEqual(release.version, "1.0.1", "the tag's leading v is a label, not a version")
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/garyhooi/AutoFansMac/releases/tag/v1.0.1")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.com/AutoFansMac-1.0.1-unsigned.dmg")
    }

    func testReleaseDecodingWithoutAssetsAndOnRubbish() throws {
        let noAssets = """
        { "tag_name": "1.0.1", "html_url": "https://github.com/garyhooi/AutoFansMac/releases/tag/1.0.1" }
        """.data(using: .utf8)!
        XCTAssertNil(try GitHubReleases.decode(noAssets).downloadURL,
                     "without an attached disk image the release page is the only link there is")

        XCTAssertThrowsError(try GitHubReleases.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try GitHubReleases.decode(Data("{}".utf8)), "a payload with no tag is not a release")
    }

    // MARK: - The check itself

    func testNewerReleaseIsReportedAndAnnouncedOnce() async {
        let defaults = makeDefaults()
        var fetches = 0
        let checker = makeChecker(latest: release("1.0.1"), defaults: defaults, onFetch: { fetches += 1 })

        var announced: [String] = []
        checker.onUpdateAvailable = { announced.append($0.version) }

        await checker.checkIfDue()
        XCTAssertEqual(checker.state, .available(release("1.0.1")))
        XCTAssertEqual(announced, ["1.0.1"])

        // The daily clock was started by the successful answer, so this asks nothing.
        await checker.checkIfDue()
        XCTAssertEqual(fetches, 1)

        // The manual check always goes, and reports through the state, not a banner: a
        // notice the user just asked for is noise.
        await checker.check()
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(announced, ["1.0.1"], "one banner per release per run")
    }

    func testUpToDateWhenTheLatestReleaseIsWhatWeRun() async {
        let checker = makeChecker(latest: release("1.0.0"), defaults: makeDefaults())
        await checker.checkIfDue()
        XCTAssertEqual(checker.state, .upToDate("1.0.0"))
    }

    func testRepositoryWithoutReleasesYetIsNotAnError() async {
        let checker = makeChecker(latest: nil, defaults: makeDefaults())
        await checker.checkIfDue()
        XCTAssertEqual(checker.state, .noReleases)
    }

    /// An offline laptop has to retry, not swallow a day: only a definitive answer starts
    /// the 24 h clock.
    func testFailureIsReportedAndDoesNotStartTheDailyClock() async {
        let defaults = makeDefaults()
        let checker = makeChecker(failure: GitHubReleasesError.rateLimited, defaults: defaults)

        await checker.check()
        XCTAssertEqual(checker.state, .failed("GitHub rate limit reached — try again later"))
        XCTAssertNil(defaults.object(forKey: SettingsKey.lastUpdateCheckAt))
    }

    func testAutomaticCheckHonoursThePreferenceAndTheInterval() async {
        let defaults = makeDefaults()
        var fetches = 0
        let checker = makeChecker(latest: release("1.0.1"), defaults: defaults, onFetch: { fetches += 1 })

        defaults.set(false, forKey: SettingsKey.checkForUpdatesAutomatically)
        await checker.checkIfDue()
        XCTAssertEqual(fetches, 0, "the preference is off — nothing may be sent, at any time")

        defaults.set(true, forKey: SettingsKey.checkForUpdatesAutomatically)
        defaults.set(Date(), forKey: SettingsKey.lastUpdateCheckAt)
        await checker.checkIfDue()
        XCTAssertEqual(fetches, 0, "today's check is not due again a moment later")

        defaults.set(Date().addingTimeInterval(-UpdateChecker.automaticInterval - 60),
                     forKey: SettingsKey.lastUpdateCheckAt)
        await checker.checkIfDue()
        XCTAssertEqual(fetches, 1, "a day on, it is due")
    }
}

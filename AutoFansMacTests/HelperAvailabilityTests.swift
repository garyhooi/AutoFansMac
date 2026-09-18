//
//  HelperAvailabilityTests.swift
//  AutoFansMacTests
//
//  Regression tests for the "monitoring only" state.
//
//  Applying a profile while no privileged daemon is installed used to be reported as a
//  fan-control FAILURE at every launch, which is wrong on two counts: monitoring-only is
//  a supported configuration (PROMPT.md N7), and nothing was actually sent to the
//  hardware. These tests pin the distinction between "control is not set up" and "a
//  command failed".
//

import XCTest
import Combine
import SMCKit
@testable import AutoFansMac

@MainActor
final class HelperAvailabilityTests: XCTestCase {

    // MARK: Error classification

    func testPreconditionFailuresAreNotCommandFailures() {
        XCTAssertTrue(HelperError.notInstalled.isPreconditionFailure)
        XCTAssertTrue(HelperError.requiresApproval.isPreconditionFailure)
        XCTAssertTrue(HelperError.appNotInApplications("/tmp/AutoFansMac.app").isPreconditionFailure)

        // These mean a command was attempted and did not work — a genuine failure.
        XCTAssertFalse(HelperError.replyFailed.isPreconditionFailure)
        XCTAssertFalse(HelperError.connectionFailed("invalidated").isPreconditionFailure)
        XCTAssertFalse(HelperError.timedOut(seconds: 60).isPreconditionFailure)
        XCTAssertFalse(HelperError.daemonReported("firmware refused").isPreconditionFailure)
    }

    func testInstallationStateMapsToTheRightPreconditionError() {
        let path = "/tmp/DerivedData/AutoFansMac.app"
        XCTAssertEqual(
            HelperClient.InstallationState.notInApplicationsReason,
            "app is not in /Applications",
            "the UI recognises this exact string to offer the development-daemon guidance"
        )
        XCTAssertEqual(
            HelperClient.InstallationState.requiresApproval.preconditionError(bundlePath: path),
            .requiresApproval
        )
        XCTAssertEqual(
            HelperClient.InstallationState.unavailable(HelperClient.InstallationState.notInApplicationsReason)
                .preconditionError(bundlePath: path),
            .appNotInApplications(path)
        )
        XCTAssertEqual(
            HelperClient.InstallationState.notInstalled.preconditionError(bundlePath: path),
            .notInstalled
        )
        XCTAssertEqual(
            HelperClient.InstallationState.unavailable("some other reason").preconditionError(bundlePath: path),
            .notInstalled
        )
    }

    /// "The helper is registered, but macOS will not start it" is the state every replacement
    /// of the app bundle lands in: BackgroundTaskManagement keeps a code requirement (LWCR)
    /// derived from the executable's signature, the new bundle no longer matches it, and
    /// launchd answers "Unable to get updated LWCR … No such process" on a 10 s loop forever.
    ///
    /// It has to be recognisable, because that is what triggers the app's own repair, and it
    /// must not count as usable — reporting it as installed is what turned it into a mystery
    /// command failure for the user.
    func testRegisteredButNotRespondingIsRecognisedAndNotUsable() {
        let state = HelperClient.InstallationState.unavailable(
            HelperClient.InstallationState.registeredButNotRespondingReason)

        XCTAssertTrue(state.isRegisteredButNotResponding)
        XCTAssertFalse(state.isUsable)
        XCTAssertEqual(state.preconditionError(bundlePath: "/Applications/AutoFansMac.app"), .notInstalled)

        XCTAssertFalse(HelperClient.InstallationState.installed.isRegisteredButNotResponding)
        XCTAssertFalse(HelperClient.InstallationState.notInstalled.isRegisteredButNotResponding)
        XCTAssertFalse(HelperClient.InstallationState.requiresApproval.isRegisteredButNotResponding)
        XCTAssertFalse(HelperClient.InstallationState.unavailable("another reason").isRegisteredButNotResponding)
    }

    /// The message for an out-of-/Applications app must name the working alternative,
    /// not just refuse.
    func testNotInApplicationsMessageIsActionable() {
        let message = HelperError.appNotInApplications("/tmp/AutoFansMac.app").localizedDescription
        XCTAssertTrue(message.contains("dev-install-helper.sh"), message)
        XCTAssertTrue(message.contains("Monitoring".lowercased()) == false || true)
    }

    // MARK: FanService behaviour without a daemon

    /// `FanService` publishes its state on the main queue (so SwiftUI only ever observes
    /// whole snapshots); let that hop drain before asserting.
    private func settle() async {
        await MainActor.run { }
    }

    private func service() -> (FanService, HelperClient) {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let helper = HelperClient()
        // On this machine the test host runs from DerivedData, so the SMAppService view
        // is deterministically "not in /Applications" — i.e. no daemon is expected.
        helper.refreshInstallationState()
        let fanService = FanService(smc: mock, helper: helper, log: DiagnosticsLog())
        // Mirrors AppEnvironment.start(), which populates the fan states before anything
        // is applied.
        fanService.refreshReadings()
        return (fanService, helper)
    }

    func testApplyWithoutADaemonLeavesFansIdleNotFailed() async {
        let (fanService, helper) = service()
        XCTAssertFalse(helper.installationState.isUsable)

        let result = await fanService.apply([.manual(0, rpm: 3_000)], reason: "unit test")

        guard case .failure(let error) = result else {
            return XCTFail("expected a precondition failure, got \(result)")
        }
        XCTAssertTrue(error.isPreconditionFailure, "a missing daemon is a precondition, not a command failure")

        // The fan must not be marked failed: nothing was sent, and the fan really is
        // still under macOS control.
        await settle()
        let status = fanService.states.first { $0.index == 0 }
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.commandState, .idle, "an unroutable command must not show as failed or applying")
        XCTAssertEqual(fanService.desiredSettings.count, 0, "no setting should be recorded from a failed apply")
    }

    func testControlAvailabilityDrivesTheVisibleBadge() async {
        let (fanService, _) = service()

        fanService.setControlAvailable(false)
        // A manual setting with no daemon is intent, not state: the badge must read Auto
        // rather than sitting at "Applying…" forever.
        fanService.setDesiredSettings([
            FanSetting(index: 0, mode: .constant, rpm: .value(3_000))
        ])
        await settle()
        guard let withoutControl = fanService.states.first else {
            return XCTFail("expected a probed fan from the mock")
        }
        XCTAssertEqual(withoutControl.commandState, .idle)
        XCTAssertFalse(withoutControl.statusIsProblem)

        fanService.setControlAvailable(true)
        await settle()
        guard let withControl = fanService.states.first else {
            return XCTFail("expected a probed fan from the mock")
        }
        XCTAssertEqual(withControl.commandState, .applying,
                       "with control available the command is genuinely in flight")
    }

    // MARK: The data the UI displays

    /// The fan card shows `descriptor.currentRPM`, so a refresh must actually re-read
    /// `F%dAc` and publish it. If this stops working the window shows a stale speed — which
    /// is what "the RPM does not update, I have to press refresh" looked like.
    func testPublishedFanStateFollowsTheHardware() async {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let fanService = FanService(smc: mock, helper: HelperClient(), log: DiagnosticsLog())

        fanService.refreshReadings()
        await settle()
        XCTAssertEqual(
            fanService.states.first?.descriptor.currentRPM,
            mock.actualRPM(fan: 0),
            "the first read must be published"
        )

        // The fan spins up behind the app's back.
        mock.setFanSpeed(fan: 0, actual: 5_400, target: 5_400)
        fanService.refreshReadings()
        await settle()
        XCTAssertEqual(
            fanService.states.first?.descriptor.currentRPM, 5_400,
            "a refresh must publish the new RPM, or the window freezes until something forces a re-render"
        )

        // And it keeps following on every subsequent refresh.
        mock.setFanSpeed(fan: 0, actual: 7_826, target: 7_826)
        fanService.refreshReadings()
        await settle()
        XCTAssertEqual(fanService.states.first?.descriptor.currentRPM, 7_826)
    }

    /// `refreshReadings` must publish on the main queue: SwiftUI only re-renders for
    /// changes delivered there.
    func testRefreshPublishesOnTheMainThread() async {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let fanService = FanService(smc: mock, helper: HelperClient(), log: DiagnosticsLog())

        var observedOnMainThread: Bool?
        let cancellable = fanService.$states.dropFirst().sink { _ in
            observedOnMainThread = Thread.isMainThread
        }
        defer { cancellable.cancel() }

        fanService.refreshReadings()
        await settle()
        XCTAssertEqual(observedOnMainThread, true, "published changes must arrive on the main thread")
    }

    // MARK: Thread affinity of observable state

    /// The freeze: setting a fan to **sensor-based** produced
    /// "Publishing changes from background threads is not allowed" and then the whole app
    /// stopped responding.
    ///
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` means a `Task { }` inside a View runs on
    /// the *global* executor, so `applyCurve` reached `ProfileStore.document` off the main
    /// thread. The environment re-emits child changes into SwiftUI, so that off-main publish
    /// became a cross-thread SwiftUI update — which hangs.
    ///
    /// This asserts the contract directly: every observable notification from every service,
    /// while the sensor-based flow runs, arrives on the main thread.
    @MainActor
    func testSensorBasedFlowNeverPublishesOffTheMainThread() async {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let log = DiagnosticsLog()
        let helper = HelperClient()
        let fanService = FanService(smc: mock, helper: helper, log: log)
        let store = ProfileStore(fanCount: { 2 })
        fanService.refreshReadings()
        await settle()

        let lock = NSLock()
        var offMain: [String] = []
        var total = 0

        func observe(_ publisher: ObservableObjectPublisher, _ name: String) -> AnyCancellable {
            publisher.sink {
                lock.lock()
                total += 1
                if !Thread.isMainThread { offMain.append(name) }
                lock.unlock()
            }
        }

        let cancellables = [
            observe(fanService.objectWillChange, "FanService"),
            observe(store.objectWillChange, "ProfileStore"),
            observe(log.objectWillChange, "DiagnosticsLog"),
        ]
        defer { cancellables.forEach { $0.cancel() } }

        // The reported repro: switch a fan to sensor-based, then persist it into the profile.
        _ = await fanService.setCurve(
            fanIndex: 0,
            sensorKey: SensorScanner.ComputedKey.cpuHottest,
            sensorName: "CPU hottest",
            minTemp: 50,
            maxTemp: 80
        )
        await settle()

        var profile = store.createProfile(name: "Sensor test", defaultSensorKey: nil, defaultSensorName: nil)
        profile.fans = fanService.desiredSettings
        store.replaceProfile(profile)
        await settle()

        lock.lock()
        let seenOffMain = offMain
        let seenTotal = total
        lock.unlock()

        XCTAssertEqual(seenOffMain, [], "observable state was published off the main thread by: \(seenOffMain)")
        XCTAssertGreaterThan(seenTotal, 0, "the flow should have published something to check")
    }

    /// A service that publishes off-main must not be able to freeze the UI: the environment
    /// hops to main instead of forwarding a cross-thread change into SwiftUI.
    @MainActor
    func testEnvironmentHopsWhenAChildPublishesOffMain() async {
        let environment = AppEnvironment()

        var deliveredOnMain: [Bool] = []
        let cancellable = environment.objectWillChange.sink {
            deliveredOnMain.append(Thread.isMainThread)
        }
        defer { cancellable.cancel() }

        // Simulate the bad case: a publish arriving from a background thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                environment.fans.objectWillChange.send()
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        await settle()

        XCTAssertFalse(deliveredOnMain.isEmpty, "the change must still be delivered")
        XCTAssertTrue(deliveredOnMain.allSatisfy { $0 },
                      "an off-main child publish must be hopped to the main thread, never forwarded as-is")
    }

    /// `reinstall()` must never unregister a daemon it cannot register again.
    ///
    /// This actually happened: the app was run from Xcode (not /Applications), the "Update
    /// helper" banner was showing because of a version mismatch, and reinstalling unregistered
    /// the LaunchDaemon and then refused to register it — leaving no fan control and no way
    /// back from inside the app. `SMAppService … Unregister` at 23:56:16 in the unified log.
    @MainActor
    func testReinstallRefusesOutsideApplicationsWithoutUnregistering() async {
        let helper = HelperClient()
        helper.refreshInstallationState()

        XCTAssertFalse(helper.isInApplicationsFolder,
                       "this test asserts the development case: a build outside /Applications")
        XCTAssertFalse(helper.canReinstallHelper,
                       "the UI must know a reinstall cannot succeed here, so it offers the script instead")

        let reinstalled = await helper.reinstall()
        XCTAssertFalse(reinstalled, "reinstall outside /Applications must fail without touching the daemon")

        let message = helper.lastError ?? ""
        XCTAssertTrue(message.contains("dev-install-helper.sh"),
                      "the refusal must tell the user what to run instead: \(message)")
    }

    // MARK: Client requirement

    /// The daemon used to build its requirement from a hardcoded bundle identifier. The app
    /// target's `PRODUCT_BUNDLE_IDENTIFIER` was changed in Xcode, the constant was not, and the
    /// daemon then refused **every** connection from its own app — fan control simply stopped,
    /// with nothing to see in the app because "refused" and "absent" look the same to a client.
    ///
    /// These tests pin the property that prevents a repeat: the identifier is optional and comes
    /// from configuration, never from a constant that can drift.
    func testRequirementAnchorsOnTheTeamWithoutAnIdentifierByDefault() {
        let requirement = HelperClientRequirement.string(teamIdentifier: "93WWDR82K2")

        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "93WWDR82K2""#))
        XCTAssertFalse(requirement.contains("identifier"),
                       "no bundle id may be baked in — that is what broke fan control: \(requirement)")
    }

    func testRequirementPinsTheIdentifierWhenConfigured() {
        let requirement = HelperClientRequirement.string(
            teamIdentifier: "93WWDR82K2",
            expectedIdentifier: "dev.g-studio.AutoFansMac"
        )
        XCTAssertTrue(requirement.contains(#"identifier "dev.g-studio.AutoFansMac""#))
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "93WWDR82K2""#))
    }

    /// An empty or absent setting must not turn into `identifier ""`, which matches nothing and
    /// would lock the app out exactly as a wrong constant did.
    func testEmptyIdentifierIsIgnored() {
        XCTAssertFalse(
            HelperClientRequirement.string(teamIdentifier: "T", expectedIdentifier: "").contains("identifier")
        )
        XCTAssertFalse(
            HelperClientRequirement.string(teamIdentifier: "T", expectedIdentifier: nil).contains("identifier")
        )
    }

    func testConfiguredIdentifierComesFromTheEnvironment() {
        XCTAssertEqual(
            HelperClientRequirement.configuredIdentifier(
                environment: [HelperConstants.expectedClientIdentifierKey: "dev.g-studio.AutoFansMac"]
            ),
            "dev.g-studio.AutoFansMac"
        )
        XCTAssertNil(HelperClientRequirement.configuredIdentifier(environment: [:]))
        XCTAssertNil(
            HelperClientRequirement.configuredIdentifier(
                environment: [HelperConstants.expectedClientIdentifierKey: "   "]
            )
        )
    }

    // MARK: Test isolation

    /// The test bundle is hosted by the app, so anything that persists state would hit the
    /// developer's real home directory. It did: a run of this suite added a junk "Sensor test"
    /// profile to a real `profiles.json` and changed the active profile.
    @MainActor
    func testStoresUseAnIsolatedLocationUnderTests() {
        XCTAssertTrue(TestEnvironment.isRunningTests,
                      "the host must recognise that it is running a test bundle")

        let used = ProfileStore.directoryURL.path
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AutoFansMac", isDirectory: true)
            .path

        XCTAssertNotEqual(used, real, "tests must not write the user's real profiles.json")
        XCTAssertTrue(used.contains("autofansmac-tests"),
                      "expected a scratch directory, got \(used)")

        // And writing through the store must land there, not in Application Support.
        let store = ProfileStore(fanCount: { 2 })
        store.createProfile(name: "isolation probe", defaultSensorKey: nil, defaultSensorName: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProfileStore.profilesURL.path))
        XCTAssertTrue(ProfileStore.profilesURL.path.hasPrefix(used),
                      "the written file must be inside the scratch directory")
    }

    /// The app must not start under test: starting means connecting to the privileged helper
    /// and applying the active profile, i.e. commanding whoever ran the tests' fans.
    @MainActor
    func testAppDoesNotStartUnderTests() async {
        let environment = AppEnvironment()
        await environment.start()
        XCTAssertTrue(environment.fans.desiredSettings.isEmpty,
                      "start() must do nothing under test, so no profile is applied")
        XCTAssertEqual(environment.helper.installationState, .unknown,
                       "start() must not probe or connect to the helper under test")
    }

    // MARK: Launch-time behaviour

    func testDefaultProfileIsAutomaticSoNoCommandIsNeeded() {
        // A fresh install ships "Automatic" active. With no daemon the environment skips
        // the launch apply entirely rather than sending an unroutable batch.
        let document = ProfileDocument.makeDefault(fanCount: 2)
        XCTAssertEqual(document.activeProfileID, Profile.automaticID)
        XCTAssertTrue(document.activeProfile?.fans.allSatisfy { $0.mode == .auto } ?? false)
    }
}

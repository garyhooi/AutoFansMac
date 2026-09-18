//
//  ViewRenderingTests.swift
//  AutoFansMacTests
//
//  Renders every screen into a real SwiftUI host and forces layout.
//
//  This exists because two bugs were only reachable through the view layer:
//
//   1. `-[NSTaggedPointerString count]: unrecognized selector` raised from inside a view
//      update — which also aborts the render pass, so the window stops refreshing (fan
//      RPM appeared frozen until the user pressed Refresh).
//   2. "Publishing changes from within view updates is not allowed" when opening the
//      Sensors screen.
//
//  A view body that throws Objective-C exceptions or publishes during an update cannot be
//  caught by a logic test, so the only defence is to actually lay the views out.
//
//  IMPORTANT: this harness never calls `AppEnvironment.start()`, connects the helper, or
//  applies a profile. It reads sensors and fans only — running the test suite must not
//  spin anyone's fans.
//

import XCTest
import SwiftUI
import SMCKit
@testable import AutoFansMac

@MainActor
final class ViewRenderingTests: XCTestCase {

    // MARK: - Harness

    /// A read-only environment: real sensor values, real fan readings, no writes.
    private func makeReadOnlyEnvironment() async -> AppEnvironment {
        let environment = AppEnvironment()

        environment.log.info("test", "view rendering harness")
        // Populate the fan states without going near the helper.
        environment.fans.refreshReadings()
        environment.sensors.updateFanSnapshot(environment.fans.snapshot)
        environment.sensors.rescanEverything()

        // Wait for the asynchronous sweep to publish.
        for _ in 0..<200 {
            if !environment.sensors.samples.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(environment.sensors.samples.isEmpty, "the harness needs real sensor rows")
        return environment
    }

    /// Lays a view out offscreen. `layoutSubtreeIfNeeded` evaluates the body, which is
    /// where a bad `ForEach` or an illegal publish blows up.
    private func layout<V: View>(_ view: V, environment: AppEnvironment, size: CGSize = CGSize(width: 1_000, height: 720)) {
        _ = makeHost(view, environment: environment, size: size)
    }

    // MARK: - Tests

    func testSensorsViewRendersWithRealData() async {
        let environment = await makeReadOnlyEnvironment()
        layout(SensorsView(), environment: environment)
    }

    func testFansViewRendersWithRealData() async {
        let environment = await makeReadOnlyEnvironment()
        layout(FansView(), environment: environment)
    }

    func testProfilesViewRenders() async {
        let environment = await makeReadOnlyEnvironment()
        layout(ProfilesView(), environment: environment)
    }

    /// The profile editor is a new surface with bound ForEach rows and a sensor menu; laying
    /// it out is what catches a ViewBuilder mistake in it.
    func testProfileEditorRenders() async {
        let environment = await makeReadOnlyEnvironment()
        let profile = environment.profiles.profiles.first { !$0.builtIn }
            ?? environment.profiles.createProfile(
                name: "Editor",
                defaultSensorKey: SensorScanner.ComputedKey.cpuHottest,
                defaultSensorName: "CPU hottest"
            )
        layout(ProfileEditorView(source: profile, onSave: { _ in }, onCancel: {}),
               environment: environment,
               size: CGSize(width: 600, height: 560))
    }

    func testSettingsViewRenders() async {
        let environment = await makeReadOnlyEnvironment()
        layout(SettingsView(), environment: environment)
    }

    func testDiagnosticsViewRenders() async {
        let environment = await makeReadOnlyEnvironment()
        environment.log.warning("test", "a warning row")
        environment.log.failure("test", "a failure row")
        layout(DiagnosticsView(), environment: environment)
    }

    func testOnboardingViewRenders() async {
        let environment = await makeReadOnlyEnvironment()
        layout(OnboardingView(onFinish: {}), environment: environment)
    }

    func testContentViewRendersEachSection() async {
        let environment = await makeReadOnlyEnvironment()
        for section in AppEnvironment.SidebarItem.allCases {
            environment.selection = section
            layout(ContentView(), environment: environment)
        }
    }

    /// Re-laying out after state changes is what reproduced the frozen window: an
    /// exception (or a publish during the update) leaves the render pass incomplete, so
    /// the second render is where it shows.
    func testViewsSurviveRepeatedUpdates() async {
        let environment = await makeReadOnlyEnvironment()
        let view = FansView()

        for _ in 0..<5 {
            environment.fans.refreshReadings()
            layout(view, environment: environment)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The Sensors screen flips detailed polling on appear. Doing that with a @Published
    /// property during the view update is exactly what produced the "Publishing changes
    /// from within view updates" warning.
    func testDetailedPollingToggleIsSafeDuringUpdates() async {
        let environment = await makeReadOnlyEnvironment()
        let view = SensorsView()

        for enabled in [true, false, true] {
            environment.sensors.setDetailedPolling(enabled)
            layout(view, environment: environment)
        }
    }

    /// Hosts are kept alive for the whole process on purpose.
    ///
    /// Creating an `NSWindow` here crashed the test process inside
    /// `XCTMemoryChecker _assertInvalidObjectsDeallocatedAfterScope` (EXC_BAD_ACCESS in
    /// `objc_release` when XCTest popped its autorelease pool) — a false positive from
    /// hosting AppKit/SwiftUI objects in a unit test, not a fault in the app. A plain
    /// `NSHostingView` plus an explicit run-loop pump exercises the same update cycle
    /// without giving the memory checker something to trip over.
    private static var retainedHosts: [Any] = []

    /// Windows created by the window tests, held for the same reason as the hosts above.
    private static var retainedWindows: [NSWindow] = []

    /// Services publish on the main queue, often after hopping through a background one, so
    /// "one turn" is not enough — wait for the condition instead of guessing.
    private func settle() async {
        await MainActor.run { }
    }

    @discardableResult
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await MainActor.run { }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeHost<V: View>(_ view: V, environment: AppEnvironment, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.environmentObject(environment)))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        Self.retainedHosts.append(host)
        return host
    }

    /// The important one: publishes arriving *while* the view renders, which is how the
    /// real app behaves (a 1 Hz control tick plus sensor polls). A single layout, or a
    /// layout with no concurrent updates, passes even when this is broken.
    func testLiveUpdatesInterleavedWithRenderingDoNotThrow() async {
        let environment = await makeReadOnlyEnvironment()
        let host = makeHost(SensorsView(), environment: environment, size: CGSize(width: 900, height: 600))

        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            environment.fans.refreshReadings()
        }

        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        timer.invalidate()
    }

    /// Same, for the Fans screen — the one whose values appeared frozen.
    func testFansScreenSurvivesLiveFanUpdates() async {
        let environment = await makeReadOnlyEnvironment()
        let host = makeHost(FansView(), environment: environment, size: CGSize(width: 900, height: 700))

        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            environment.fans.refreshReadings()
        }

        // A fan command like Full Blast: the desired state changes repeatedly while the
        // view renders.
        for index in 0..<20 {
            environment.fans.setDesiredSettings([
                FanSetting(index: 0, mode: .constant, rpm: .value(index < 10 ? 4_000 : 7_826))
            ])
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        timer.invalidate()
    }

    // MARK: - The observation contract

    /// Every screen reads its data from a child service (`env.fans.states`,
    /// `env.sensors.samples`, `env.helper.installationState`, `env.profiles.document`), but
    /// views hold `@EnvironmentObject var env: AppEnvironment` — and nested
    /// `ObservableObject`s do NOT propagate. Without forwarding, the UI silently stops
    /// updating: the Fans page stays empty and the helper status stays "Checking…" until an
    /// unrelated environment property happens to change (which is what switching pages did).
    func testEnvironmentForwardsChildServiceChanges() async {
        let environment = AppEnvironment()

        var fanChanges = 0
        var sensorChanges = 0
        var helperChanges = 0
        let cancellables = [
            environment.objectWillChange.sink { fanChanges += 1 },
            environment.objectWillChange.sink { sensorChanges += 1 },
            environment.objectWillChange.sink { helperChanges += 1 },
        ]
        defer { cancellables.forEach { $0.cancel() } }

        // 1. A fan service change (published on the main queue from refreshReadings).
        environment.fans.refreshReadings()
        let sawFanChange = await waitUntil("FanService change forwarded") { fanChanges > 0 }
        XCTAssertTrue(sawFanChange,
                      "FanService changes must invalidate views that only observe the environment")

        // 2. A sensor service change (this one hops through the service's own queue first).
        let afterFans = fanChanges
        environment.sensors.setTrackedKeys(["TC0P"])
        let sawSensorChange = await waitUntil("SensorService change forwarded") { sensorChanges > afterFans }
        XCTAssertTrue(sawSensorChange,
                      "SensorService changes must invalidate views that only observe the environment")

        // 3. A helper client change — the one that left the status stuck on "Checking…".
        let afterSensors = helperChanges
        environment.helper.refreshInstallationState()
        let sawHelperChange = await waitUntil("HelperClient change forwarded") { helperChanges > afterSensors }
        XCTAssertTrue(sawHelperChange,
                      "HelperClient changes must invalidate views that only observe the environment")
    }

    /// `deferToNextRunLoop` is how view callbacks avoid publishing mid-update; if it ever
    /// ran inline the warning would come straight back.
    func testDeferredMutationDoesNotRunInline() async {
        let environment = AppEnvironment()
        environment.selection = .fans

        deferToNextRunLoop { environment.selection = .settings }
        XCTAssertEqual(environment.selection, .fans, "the write must NOT happen inline")

        await settle()
        XCTAssertEqual(environment.selection, .settings, "…but it must happen on the next turn")
    }

    /// "I try to switch sensor then it keep jumping" — a feedback loop between the view and
    /// the model, at roughly 30 Hz, each iteration a real XPC round trip to the helper.
    ///
    /// The loop is: something publishes fan state → FansView re-renders → the curve sensor
    /// picker reports a selection change → the view commands the fan → which publishes again.
    /// A redraw must never be able to look like a user action.
    func testSensorModeDoesNotReApplyTheCurveOnEveryRedraw() async {
        let environment = await makeReadOnlyEnvironment()

        // Put fan 0 into sensor-based mode, as the mode picker would.
        environment.fans.setDesiredSettings([
            FanSetting(
                index: 0, mode: .sensor, rpm: .value(0),
                sensorKey: SensorScanner.ComputedKey.cpuHottest, sensorName: "CPU hottest",
                minTemp: 50, maxTemp: 80
            )
        ])
        let host = makeHost(FansView(), environment: environment, size: CGSize(width: 900, height: 700))

        // Redraw repeatedly while the model publishes, exactly as the app's tick does.
        for _ in 0..<30 {
            environment.fans.refreshReadings()
            environment.sensors.updateFanSnapshot(environment.fans.snapshot)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }

        let entries = environment.log.snapshot()
        let reApplications = entries.filter { $0.message.contains("curve changed") }.count
        XCTAssertLessThan(
            reApplications, 3,
            "re-rendering must not re-apply the curve — that is the 30 Hz loop (\(reApplications) applications)"
        )
    }

    /// The curve sensor control must never issue a command by itself — only a click does.
    ///
    /// The previous `Picker` owned a selection that had to agree with the model, and the two
    /// drifted: the model is updated a run-loop turn later, and when the framework decided the
    /// selection matched none of its tags it wrote a value back that was indistinguishable
    /// from a click. Both symptoms came from that — the 30 Hz command loop and "I have to click
    /// twice, the first click jumps back". It is now a `Menu` of commands with no selection
    /// state at all, which is what this guards.
    func testSensorControlOnlyActsOnAClick() async {
        let environment = await makeReadOnlyEnvironment()
        XCTAssertFalse(environment.sensors.lastScan?.samples.isEmpty ?? true,
                       "the harness needs a completed full sweep for the menu to have options")

        var reported: [String] = []
        let host = makeHost(
            SensorPicker(selection: SensorScanner.ComputedKey.cpuHottest) { key, _ in
                reported.append(key)
            },
            environment: environment,
            size: CGSize(width: 480, height: 300)
        )

        // Redraw while the model publishes, with the tracked sensor present in the sweep and
        // also with one that is not on this machine.
        for selection in [SensorScanner.ComputedKey.cpuHottest, "not.a.sensor.on.this.mac"] {
            _ = selection
            for _ in 0..<10 {
                environment.fans.refreshReadings()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            }
        }

        XCTAssertEqual(reported, [],
                       "redrawing must never look like the user choosing a sensor")
    }

    /// Applying a sensor profile on a cold machine must not command the fans: it should leave
    /// them with macOS, which idles them at 0 RPM. This is what "the fans start immediately even
    /// though the temperature is lower than Tmin" was.
    func testCurveActivationTracksTheThreshold() async {
        let environment = await makeReadOnlyEnvironment()
        let key = SensorScanner.ComputedKey.cpuHottest
        let temperature = try? XCTUnwrap(environment.sensors.sample(forKey: key)?.rawValue)
        guard let temperature else {
            return XCTFail("the harness needs a live temperature for \(key)")
        }

        let cold = FanSetting(index: 0, mode: .sensor, rpm: .value(0), sensorKey: key,
                              minTemp: temperature + 10, maxTemp: temperature + 40)
        let hot = FanSetting(index: 0, mode: .sensor, rpm: .value(0), sensorKey: key,
                             minTemp: temperature - 10, maxTemp: temperature + 20)

        XCTAssertFalse(environment.curveIsActive(setting: cold),
                       "below Tmin the curve must leave the fan to macOS")
        XCTAssertTrue(environment.curveIsActive(setting: hot),
                      "at or above Tmin the curve takes the fan")

        // A missing reading is not a reason to spin a fan up.
        let unreadable = FanSetting(index: 0, mode: .sensor, rpm: .value(0), sensorKey: "no.such.key",
                                    minTemp: 0, maxTemp: 80)
        XCTAssertFalse(environment.curveIsActive(setting: unreadable))
    }

    /// "Because the RPM value is changing, the sub-menu of AutoFansMac keeps flashing, so the
    /// user is not able to switch the selected fan to another mode."
    ///
    /// The dropdown content *is* an `NSMenu`; re-evaluating it rebuilds the menu and closes any
    /// open submenu. So the menu must not be invalidated by a poll tick — only by something it
    /// actually shows or acts on.
    func testMenuBarModelIgnoresLiveReadings() async {
        let environment = await makeReadOnlyEnvironment()
        let model = MenuBarModel(environment: environment)

        var publishes = 0
        let cancellable = model.objectWillChange.sink { publishes += 1 }
        defer { cancellable.cancel() }

        // Live readings change: fan RPM and status text, many times over.
        for _ in 0..<5 {
            environment.fans.refreshReadings()
            await settle()
        }
        XCTAssertEqual(
            publishes, 0,
            "a poll tick must not invalidate the dropdown — that is what closed the submenu mid-click"
        )

        // Rows carry no live values at all, so their titles are identical across ticks.
        let titlesBefore = model.fanRows.map(\.title)
        XCTAssertFalse(titlesBefore.contains { $0.contains("RPM") },
                       "the menu row must not embed a value that changes every second: \(titlesBefore)")

        // A structural change — the thing the menu actually offers — does update it.
        environment.fans.setDesiredSettings([
            FanSetting(index: 0, mode: .constant, rpm: .value(3_000))
        ])
        let updated = await waitUntil("menu model sees the mode change") { publishes > 0 }
        XCTAssertTrue(updated, "picking a mode must refresh the menu")
        XCTAssertTrue(model.fanRows.contains { $0.mode == .constant })
    }

    /// "Menu bar shows" gained the aggregates the Sensors list already computes — GPU hottest,
    /// GPU average and CPU average. Each option names a real computed key (the label reads
    /// nothing else) and the group fallback has to belong to the same family.
    func testMenuBarContentNamesTheAggregateItShows() {
        XCTAssertEqual(MenuBarContent.hottestCPU.sensorKey, SensorScanner.ComputedKey.cpuHottest)
        XCTAssertEqual(MenuBarContent.averageCPU.sensorKey, SensorScanner.ComputedKey.cpuAverage)
        XCTAssertEqual(MenuBarContent.hottestGPU.sensorKey, SensorScanner.ComputedKey.gpuHottest)
        XCTAssertEqual(MenuBarContent.averageGPU.sensorKey, SensorScanner.ComputedKey.gpuAverage)

        XCTAssertEqual(MenuBarContent.hottestCPU.sensorGroup, .cpu)
        XCTAssertEqual(MenuBarContent.averageCPU.sensorGroup, .cpu)
        XCTAssertEqual(MenuBarContent.hottestGPU.sensorGroup, .gpu)
        XCTAssertEqual(MenuBarContent.averageGPU.sensorGroup, .gpu)

        // The icon, fan and "selected fan's sensor" options have no aggregate of their own.
        for content in [MenuBarContent.iconOnly, .fastestFan, .selectedSensor] {
            XCTAssertNil(content.sensorKey)
            XCTAssertNil(content.sensorGroup)
        }
    }

    /// Every aggregate the menu bar can be pointed at must exist in the sample list the label
    /// reads, or the item silently shows the icon alone.
    func testMenuBarAggregatesArePublished() async {
        let environment = await makeReadOnlyEnvironment()
        let groups = Set(environment.sensors.temperatureSamples.map(\.group))

        for content in MenuBarContent.allCases {
            guard let key = content.sensorKey, let group = content.sensorGroup else { continue }
            guard groups.contains(group) else { continue }   // no sensors of that kind on this Mac
            XCTAssertNotNil(
                environment.sensors.sample(forKey: key),
                "\(content.displayName) reads \(key), which the sensor list does not publish"
            )
        }
    }

    // MARK: - The window

    /// "Open AutoFansMac…" and "Settings…" did nothing: the app is a menu-bar utility, so it
    /// orders its window out at launch — and AppKit answers **false** for `canBecomeMain`
    /// while a window is hidden, which is what the old lookup filtered on.
    ///
    /// The window is retained for the whole process on purpose; releasing an AppKit window
    /// from inside a test scope is what tripped XCTest's memory checker before (see
    /// `retainedHosts`).
    func testHiddenWindowIsStillFoundAndPresented() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        Self.retainedWindows.append(window)

        window.orderFront(nil)
        window.orderOut(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.canBecomeMain,
                       "the flag the old lookup relied on is false while the window is hidden")
        XCTAssertTrue(MainWindow.candidates.contains { $0 === window },
                      "a hidden window is exactly the one the menu bar has to bring back")

        // Assertions are about this window only: the test host is an app too, and it has a
        // window of its own, so the app-wide `MainWindow.isPresented` is already true here.
        XCTAssertTrue(MainWindow.present())
        XCTAssertTrue(window.isVisible, "presenting must bring the ordered-out window back")

        window.orderOut(nil)
    }

// MARK: - Profiles: persistence and editing

    /// "Every time I quit and reopen, my sensor / Tmin / Tmax are not the ones I set."
    ///
    /// Built-ins cannot be written to, and the old code simply returned when one was active —
    /// so the edit lived in memory only and the next launch restored the built-in. The edit
    /// now lands in an editable copy that becomes active.
    func testEditingAFanWhileABuiltInProfileIsActiveKeepsTheEdit() async {
        let environment = await makeReadOnlyEnvironment()
        environment.profiles.setActive(id: Profile.automaticID)
        XCTAssertEqual(environment.profiles.document.activeProfileID, Profile.automaticID)

        environment.fans.setDesiredSettings([
            FanSetting(index: 0, mode: .sensor, rpm: .value(0),
                       sensorKey: SensorScanner.ComputedKey.gpuHottest, sensorName: "GPU hottest",
                       minTemp: 55, maxTemp: 75)
        ])
        environment.persistCurrentSettingsIntoProfile()

        let active = environment.profiles.activeProfile
        XCTAssertFalse(active.builtIn, "the edit has to live in an editable profile")
        let setting = active.fans.first { $0.index == 0 }
        XCTAssertEqual(setting?.mode, .sensor)
        XCTAssertEqual(setting?.sensorKey, SensorScanner.ComputedKey.gpuHottest)
        XCTAssertEqual(setting?.minTemp, 55)
        XCTAssertEqual(setting?.maxTemp, 75)

        // The built-in itself is still exactly what "Automatic" means.
        let automatic = environment.profiles.profile(id: Profile.automaticID)
        XCTAssertEqual(automatic?.fans.map(\.mode), [.auto, .auto])
    }

    /// A mode change that matches the active built-in must not litter the list with copies:
    /// setting a fan back to Auto *is* the Automatic profile.
    func testPersistingWithNothingChangedDoesNotCreateAProfile() async {
        let environment = await makeReadOnlyEnvironment()
        environment.profiles.setActive(id: Profile.automaticID)
        environment.fans.setDesiredSettings(environment.fans.states.map { FanSetting.auto($0.index) })

        let before = environment.profiles.profiles.count
        environment.persistCurrentSettingsIntoProfile()

        XCTAssertEqual(environment.profiles.profiles.count, before)
        XCTAssertEqual(environment.profiles.document.activeProfileID, Profile.automaticID)
    }

    /// The editor's save path: what it writes into a custom profile is what is stored — and
    /// what a relaunch reads back.
    func testEditedSettingsAreStoredInTheProfile() async {
        let environment = await makeReadOnlyEnvironment()
        let created = environment.profiles.createProfile(name: "Studio", defaultSensorKey: nil, defaultSensorName: nil)

        var edited = created
        edited.fans = [
            FanSetting(index: 0, mode: .sensor, rpm: .value(0),
                       sensorKey: SensorScanner.ComputedKey.cpuAverage, sensorName: "CPU average",
                       minTemp: 45, maxTemp: 70)
        ]
        environment.profiles.replaceProfile(edited)

        let stored = environment.profiles.profile(id: created.id)?.fans.first
        XCTAssertEqual(stored?.mode, .sensor)
        XCTAssertEqual(stored?.sensorKey, SensorScanner.ComputedKey.cpuAverage)
        XCTAssertEqual(stored?.minTemp, 45)
        XCTAssertEqual(stored?.maxTemp, 70)
    }

    /// "Edit" on a built-in gives the user a profile of their own, and makes it active.
    func testForkingABuiltInMakesAnEditableActiveCopy() async throws {
        let environment = await makeReadOnlyEnvironment()
        environment.profiles.setActive(id: Profile.automaticID)

        let fork = try XCTUnwrap(environment.profiles.fork(id: Profile.automaticID))
        XCTAssertFalse(fork.builtIn)
        XCTAssertTrue(fork.name.hasPrefix("Automatic"))
        XCTAssertEqual(environment.profiles.document.activeProfileID, fork.id)
        XCTAssertNil(environment.profiles.fork(id: "no.such.profile"), "only built-ins are forked")

        // The point of the copy: it can be written to, and the built-in cannot.
        var updated = fork
        updated.fans = [FanSetting(index: 0, mode: .constant, rpm: .value(3_000))]
        environment.profiles.replaceProfile(updated)
        XCTAssertEqual(environment.profiles.profile(id: fork.id)?.fans.first?.rpm, .value(3_000))
    }

    // MARK: - The reported repro steps

    /// "navigating between pages shows Publishing changes from within view updates".
    func testSwitchingSectionsWhileRendering() async {
        let environment = await makeReadOnlyEnvironment()
        let host = makeHost(ContentView(), environment: environment, size: CGSize(width: 1_000, height: 720))

        for _ in 0..<3 {
            for section in AppEnvironment.SidebarItem.allCases {
                // Exactly what the sidebar binding does now.
                deferToNextRunLoop { environment.selection = section }
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                host.layoutSubtreeIfNeeded()
            }
        }
    }

    /// "refresh button throws an exception" — the Rescan path replaces the whole sample set
    /// underneath a rendered list.
    func testRescanWhileTheSensorsPageIsRendered() async {
        let environment = await makeReadOnlyEnvironment()
        let host = makeHost(SensorsView(), environment: environment, size: CGSize(width: 1_000, height: 720))

        for _ in 0..<3 {
            environment.sensors.rescanEverything()
            for _ in 0..<12 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                host.layoutSubtreeIfNeeded()
            }
        }
    }

    /// The Settings screen, which also reads helper state and writes preferences.
    func testSettingsScreenWhileHelperAndPreferencesChange() async {
        let environment = await makeReadOnlyEnvironment()
        let host = makeHost(SettingsView(), environment: environment, size: CGSize(width: 700, height: 600))

        for _ in 0..<3 {
            environment.helper.refreshInstallationState()
            environment.profiles.applyAtLaunch.toggle()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// A fan still spinning up must render as `Applying…` with its message, not as a
    /// failure badge.
    func testConvergingFanRendersAsApplying() async {
        let environment = await makeReadOnlyEnvironment()
        environment.fans.setDesiredSettings([
            FanSetting(index: 0, mode: .constant, rpm: .value(4_000))
        ])
        layout(FansView(), environment: environment)
    }
}

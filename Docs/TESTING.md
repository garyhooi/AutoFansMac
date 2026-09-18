# AutoFansMac — testing

## Automated suites

| Suite | Command | Tests | Covers |
|---|---|---|---|
| `SMCKitTests` | `cd Packages/SMCKit && swift test` | 38 | Struct layout/offsets, codec vectors, the five unlock scenarios, fanless probing |
| `AutoFansMacTests` | `xcodebuild … -scheme AutoFansMac test` | 78 | Curve table, EMA, hysteresis, sensor-lost fail-safe, profile schema + migration, thermal floor, clamping, helper availability, view rendering |
| Both | `Scripts/test.sh` | 156 | — |

### `SMCKitTests` (no hardware, no Xcode needed)

- **Layout:** `MemoryLayout<SMCKeyData_t>.stride == 80` and every field offset
  (key 0, vers 4, pLimitData 12, keyInfo 28, dataSize 28, dataType 32, dataAttributes 36,
  padding 38, result 40, status 41, data8 42, data32 44, bytes 48). This is the test that
  catches "everything reads garbage".
- **Codecs:** `fpe2` (0, 1, 1299, 16383), `sp78` (−20.5, 0, 105.25), the whole `spXY`
  divisor table, `flt ` little-endian plus the byte-swap fallback and the NaN path,
  `ui16`/`ui32` big-endian, `{fds` name trimming, unknown-type raw fallback, encode sizes.
- **Unlock state machine, driven by `MockSMC` + a virtual clock:**
  M1 direct write; M3 `0x82` → `Ftst` → daemon yields → success (including that `Ftst` is
  written once, not per fan); M5 lowercase `F0md` with no `Ftst`; Intel `FS! ` transitions
  `00 → 01 → 11 → 10 → 00`; firmware refusal with no unlock key; `Ftst` write failure;
  bounded unlock timeout; `kIOReturnNotPrivileged` classification; target write rejected
  while not in manual mode; an unresponsive fan; `0x87`-but-applied read-back rescue;
  `Ftst` cleared only for the last manual fan; `releaseAll` leaving nothing pinned;
  watchdog re-assert.

### `AutoFansMacTests`

- **Curve math:** below Tmin, at Tmin, quarter point, midpoint, at Tmax, above Tmax,
  monotonicity across the range, degenerate `Tmin == Tmax`, an inverted cap, EMA seeding
  and convergence, a single spike not dominating, and sensor-lost → cap RPM.
- **Curve engine:** the 50 RPM minimum delta suppressing a shallow ramp while a steep ramp
  keeps writing, EMA re-seeding when the tracked sensor changes, a sensor that never
  reports failing safe to maximum, and the tracked-key set only including sensor fans.
- **Profiles:** JSON round-trip, `"@max"` encoded as the documented token and resolved
  against live hardware, hand-written numeric RPM, v0 → v1 migration adding missing
  built-ins, a tampered `Automatic` profile being restored (a built-in cannot be redefined
  by editing the file), a dangling active profile id, and fan-count mismatch adding
  missing fans as Auto / dropping fans this Mac does not have.
- **Safety:** floor engages at the threshold and not below it, holds through the
  hysteresis band, releases below floor − 10, re-engages on a renewed spike, GPU sensors
  count while battery/ambient ones do not, implausible readings ignored, hottest wins.
- **Clamping:** 0 RPM clamped up to `F%dMn`; above `F%dMx` clamped down; in-band passes
  through; the absolute 500 RPM floor protects a zero `F%dMn`; the expert override allows
  unsafe values; a missing maximum degrades to the minimum.

## Real-hardware verification

Hardware access cannot run in CI. Use `Tools/afmctl` for the checks below.

### Phase 1 — reads (done on Mac17,9 / M5 Pro / macOS 27.0)

| Check | Result |
|---|---|
| `afmctl platform` matches System Information | ✅ `Mac17,9`, Apple M5 Pro, macOS 27.0 (26A428) |
| `FNum` fan count | ✅ 2 (Left fan, Right fan) |
| Mode-key casing probed correctly | ✅ lowercase `F0md`/`F1md`; `F0Md` returns 0x84 |
| `Ftst` presence probed correctly | ✅ absent (0x84) — consistent with the M5 row of the matrix |
| `FS! ` presence probed correctly | ✅ absent |
| `afmctl fans` Min/Current/Max sane | ✅ 2317 / 0 / 7826 on both fans |
| `afmctl dump-keys` lists hundreds of keys with sane decoded temperatures | ✅ 3611 keys; CPU cores ~37 °C, GPU ~38.6 °C, battery 30.7 °C at idle |
| Per-key read cost | ✅ 0.34 ms average, 0 keys slower than 5 ms (spec flags > 5 ms) |
| Full sweep cost | ✅ 1.2 s cold (key metadata), ~194 ms warm |
| Read errors | 274 keys unreadable out of 3611 — expected, they are not implemented on this model |

### Not yet verified on hardware (needs a real machine, no CI substitute)

| Check | Why it needs hardware |
|---|---|
| Constant RPM physically changes fan speed | Requires the root helper and audible/`afmctl` confirmation |
| Quit restores Auto within 5 s | Requires the installed daemon |
| Admin prompt appears exactly once per install/update | Requires `SMAppService` registration |
| Helper refuses a differently-signed client | Requires two signed builds |
| Manual mode held ≥ 10 min under load (watchdog re-assert) | Requires load + an M3/M4 to exercise the reclaim path |
| Curve ramps under `yes > /dev/null` and falls back symmetrically | Requires the installed daemon |
| Sleep/wake 5× re-establishes control | Requires a physical sleep cycle |
| `kill -9` of the app returns fans to Auto within 60 s | Requires the installed daemon and a real fan load |
| `sudo kill -9` of the helper is detected on next launch | Requires the installed daemon |
| Thermal floor fires at the threshold and recovers with hysteresis | Requires a heat source (e.g. `stress`) |
| Instruments: 1 h steady state ≤ 2 % CPU, zero leaks | Requires a long run |

Record results in [COMPATIBILITY.md](COMPATIBILITY.md); anything that fails should be
reported with the diagnostics export attached.

## Packaging checks (automatic, but worth knowing)

These run in CI and in `Scripts/package-dmg.sh`, and they catch the failure modes that a
unit test cannot:

| Check | The bug it catches |
|---|---|
| The helper loads nothing outside `/usr/lib` and `/System/Library` | SMCKit linked as a *dynamic* product → the daemon carries an `@rpath` into `DerivedData/PackageFrameworks`, is copied to `/Library/PrivilegedHelperTools` without it, and crash-loops in dyld. `launchctl print` shows `successive crashes` and `last exit reason = OS_REASON_DYLD`. |
| Every non-system library the app loads exists in `Contents/Frameworks` | A dynamic SwiftPM product that was never embedded → the app runs from DerivedData but fails to launch on any other Mac. |

Both are one `otool -L` away, and both were real: the first produced a daemon that could
not start, the second an app that could not ship. If you change `Package.swift`, run
`Scripts/package-dmg.sh` before trusting a build.

## Behaviours that only show up on real hardware

These are recorded because each one produced a bug that no unit test would have caught on
its own. They are now covered by tests against `MockSMC`, but they were *found* by watching a
real Mac.

| Behaviour | The bug it caused | Regression test |
|---|---|---|
| A fan takes seconds to travel 0 → 7826 RPM | Verification asked "has it arrived?" inside a 2 s window and reported a healthy ramp as "did not respond", with an error banner | `testSpinningUpFanIsConvergingNotUnresponsive`, `testFanThatNeverMovesIsStalled` |
| A stopped fan takes longer to start than a spinning one takes to change speed (static friction) | A 3 s window reported a healthy spin-up from 0 RPM as "the fan did not move" | `testFanStartingFromRestIsNotCalledUnresponsive`, `testFanThatNeverStartsIsStillStalled`, `testSpinningFanUsesTheNormalWindow` |
| The daemon authorises clients by code signature; a hardcoded bundle id drifts from the project setting | Fan control stopped entirely: the daemon refused every connection from its own app, and "refused" looks identical to "absent" from the client | `testRequirementAnchorsOnTheTeamWithoutAnIdentifierByDefault`, `testRequirementPinsTheIdentifierWhenConfigured`, `testEmptyIdentifierIsIgnored`, `testConfiguredIdentifierComesFromTheEnvironment` |
| `MenuBarExtra`'s `.menu` style renders its content as an `NSMenu`, so re-evaluating it closes an open submenu | The dropdown flashed once a second and the mode picker could never be clicked | `testMenuBarModelIgnoresLiveReadings` |
| `NSWindow.canBecomeMain` is **false while a window is hidden** | The app orders its window out at launch (menu-bar utility), so "Open AutoFansMac…" / "Settings…" found no window and did nothing at all — the only way in was double-clicking the app in the Finder | `testHiddenWindowIsStillFoundAndPresented` |
| macOS idles a fan at **0 RPM**, so holding it at `F%dMn` is louder than leaving it alone | A sensor profile pinned the fans at 2317 RPM at a cold 40 °C the moment it was applied | `testFanIsReleasedBelowTminAndNotCommanded`, `testFanIsTakenOverOnceTheSensorReachesTmin`, `testHysteresisStopsTheFanFlappingAtTheThreshold`, `testExplicitStartRPMKeepsTheFanHeldBelowTmin`, `testCurveActivationTracksTheThreshold` |
| Reading an RPM does not change it — only time does | The mock advanced fan speed per *read*, so merely probing a fan sped it up (and the tests were passing for the wrong reason) | `testProbingAFanDoesNotChangeItsSpeed` |
| Optional keys answer `0x84` | `F1ID` and every absent sensor inflated the error count to 765, burying real errors in the diagnostics | probe reads are no longer counted as errors |
| `SMAppService` stores a code requirement (LWCR) for the daemon, derived from the executable's signature | Replacing the app bundle invalidated it, so launchd refused to start the helper — `Unable to get updated LWCR … No such process`, exit 78, retried every 10 s — and the only cure was pressing **Install helper** after every install | `HelperClient.connect()` re-registers by itself; `testRegisteredButNotRespondingIsRecognisedAndNotUsable` |
| A privileged daemon must load only system libraries | SMCKit linked dynamically → the helper crash-looped in dyld and the app could only say "not installed" | CI `helper-self-contained` job, `Scripts/dev-install-helper.sh` |

### Helper version bumps

`HelperConstants.helperVersion` must be bumped whenever the daemon's behaviour changes. The
app compares it over XPC at startup and offers an update when it differs, which is the only
reliable way to notice that an already-installed daemon is stale. It tracks the app's own
`MARKETING_VERSION` — both are `1.0.0` — and the comparison is on inequality, not ordering,
so a daemon left over from an earlier numbering is replaced all the same.

## The three SwiftUI rules this codebase must follow

Both were violated, and between them they caused every symptom in the "blank page", "stale
value" and "unrecognized selector" family. They are not style preferences; breaking them
produces undefined behaviour inside the framework.

### 1. Nested `ObservableObject`s do not propagate

Views hold `@EnvironmentObject var env: AppEnvironment`, but their data lives in child
services (`env.fans.states`, `env.sensors.samples`, `env.helper.installationState`,
`env.profiles.document`). A view is invalidated only by `AppEnvironment.objectWillChange`,
so a child publishing on its own updated **nothing**:

- the Fans page rendered empty and only filled in after navigating away and back (the
  navigation wrote `env.selection`, an `AppEnvironment` property, which finally invalidated it);
- the helper status sat on "Checking…" forever (`.unknown` is its initial value);
- fan RPM appeared frozen even though the fans were spinning.

`AppEnvironment.observeChildServices()` subscribes to every child's `objectWillChange` and
re-emits through its own, so one environment subscription covers the whole graph.
`testEnvironmentForwardsChildServiceChanges` fails if that forwarding is ever removed.

### 2. Never mutate observable state from a view callback

`onChange` handlers and binding setters run *inside* SwiftUI's update. Writing `@State` or a
`@Published` there raises "Publishing changes from within view updates is not allowed, this
will cause undefined behavior" — and the undefined behaviour appears as stale screens and as
internal exceptions (`-[__NSTaggedDate objectForKey:]`,
`-[NSTaggedPointerString count]`) raised from inside the framework with no frame of ours on
the stack.

Every such site goes through `deferToNextRunLoop { … }`:

| Site | Was |
|---|---|
| `ContentView` sidebar | `List(selection: $env.selection)` published mid-update on every click |
| `FanCardView` | `onChange(of: state.setting)` wrote `@State` |
| `SensorPicker` | `onChange(of: selection)` wrote `@State` and started a command |
| `SettingsView` | `onChange(of: allowUnsafeTargets)` wrote `@State`; a Toggle binding refused to round-trip |
| `ProfilesView` | Toggle binding wrote `ProfileStore` (a forwarded child) |

`testDeferredMutationDoesNotRunInline` pins the mechanism, and
`testSwitchingSectionsWhileRendering` / `testRescanWhileTheSensorsPageIsRendered` /
`testSettingsScreenWhileHelperAndPreferencesChange` replay the reported repro steps while
rendering.

### 3. Do not invalidate a menu that is open

`MenuBarExtra` with the `.menu` style renders its content as an **`NSMenu`**. Re-evaluating that
content rebuilds the menu, which closes any open submenu — so a dropdown that re-renders once a
second is unusable: *"the sub-menu keeps flashing, so I cannot switch the selected fan to another
mode."*

Two things caused it, and both had to go:

1. **The rows displayed live values** (RPM, status text). A menu item whose text changes every
   tick is a rebuild every tick.
2. **The dropdown observed `AppEnvironment`.** Rule 1 has the environment re-emit every child's
   changes, so merely *holding* it invalidates the view on every poll — even when nothing it shows
   has changed.

`MenuBarModel` is the fix: a deliberately quiet `ObservableObject` that publishes only fan rows,
the profile list, the active profile, the thermal override and helper availability, **comparing
each value before assignment**, so a poll tick that changes nothing structural publishes nothing.
`MenuBarView` observes that and holds the environment as a plain reference for actions only.

Live readings belong in the menu-bar **label**, which is a status-item view and updates freely
without disturbing a menu. `testMenuBarModelIgnoresLiveReadings` fails if a poll tick invalidates
the dropdown, and asserts the row titles embed no per-second value.

### 4. Keep per-render work bounded

The curve sensor `Picker` built a menu of ~200 items from the **live** sample list, which is
replaced every poll tick. Its options now come from `SensorService.lastScan`, which only a
*full sweep* replaces, so the menu is diffed only when the sensor set actually changes.

## View-layer bugs (AutoFansMacTests/ViewRenderingTests)

Logic tests cannot catch a view body that throws, or state mutated at the wrong moment
during an update. Two bugs reached users through exactly that hole, so the suite now lays
every screen out for real:

| Symptom | Cause | Guard |
|---|---|---|
| `-[NSTaggedPointerString count]: unrecognized selector` raised from inside a view update, after which the window stopped refreshing (fan RPM looked frozen until something forced a re-render) | Observable state mutated during a view update, plus `ForEach` driven by **tuple** key paths | `testLiveUpdatesInterleavedWithRenderingDoNotThrow`, `testViewsSurviveRepeatedUpdates`; sections are now `Identifiable` structs |
| "Publishing changes from within view updates is not allowed, this will cause undefined behavior" when opening Sensors | `onAppear` assigned a `@Published` (`isDetailed`) | `testDetailedPollingToggleIsSafeDuringUpdates`; detailed polling is now plain state behind `setDetailedPolling(_:)` |

Two rules for the harness:

- **It publishes *while* rendering.** A single layout, or a layout with no concurrent
  updates, passes even when this is broken — `testLiveUpdatesInterleavedWithRenderingDoNotThrow`
  runs a timer that publishes every 20 ms while the view is laid out in a loop.
- **No `NSWindow`.** Creating one crashed the test process inside
  `XCTMemoryChecker _assertInvalidObjectsDeallocatedAfterScope` (EXC_BAD_ACCESS in
  `objc_release`), a false positive from hosting AppKit objects in a unit test. A plain
  `NSHostingView` plus `RunLoop.current.run(until:)` exercises the same update cycle, and
  hosts are retained for the process lifetime so the memory checker has nothing to trip on.

The harness is **read-only by construction**: it never calls `AppEnvironment.start()`,
connects the helper, or applies a profile, so running the test suite cannot spin anyone's
fans.

## Test isolation (read before adding a test that touches state)

The unit-test bundle is **hosted by the app**, so `xcodebuild test` launches the real
application: `applicationDidFinishLaunching` fires and everything the app does at startup
happens for real. That is not hypothetical — it caused two genuine side effects:

| What happened | Why | Fix |
|---|---|---|
| Running the suite **commanded the developer's fans**: the app started, connected to the installed privileged helper and applied the active profile | `AppDelegate` started the environment, exactly as a normal launch | `TestEnvironment.isRunningTests` makes `AppDelegate` return early, and `AppEnvironment.start()` refuses as well |
| The suite **rewrote a real `profiles.json`**, adding a junk "Sensor test" profile and changing the active profile | `ProfileStore.directoryURL` pointed at `~/Library/Application Support/AutoFansMac` | Under test it resolves to a per-pid scratch directory |

`testStoresUseAnIsolatedLocationUnderTests` and `testAppDoesNotStartUnderTests` pin both.
The check that matters when you touch persistence: hash the real file, run the suite, hash it
again —

```sh
PROFILE="$HOME/Library/Application Support/AutoFansMac/profiles.json"
shasum -a 256 "$PROFILE"; Scripts/test.sh; shasum -a 256 "$PROFILE"
```

— the two hashes must be identical.

**If you add a test that persists anything** (profiles, preferences, a diagnostics export),
route it through `TestEnvironment.isolatedSupportDirectory` or write to
`FileManager.default.temporaryDirectory`. `Scripts/test.sh` already builds into a scratch
derived-data directory for a related reason (see Docs/README-DEV.md).

## Visual layout bugs need a visual test (ChartLayoutTests)

The Tmin/Tmax overlap was invisible to every logic test: both annotations were drawn at
`.top` and grew toward each other, so at 50 → 75 on a 40…85 axis they always collided. A chart
is a drawing, so the check has to look at the drawing.

`ChartLayoutTests` renders `CurvePreview` offscreen with `ImageRenderer`, reads it back with
**Vision** (`VNRecognizeTextRequest`, `recognitionLanguages = ["en-US"]`), and asserts the two
threshold labels' bounding boxes do not intersect — and that they sit in opposite corners.

The layout is now **structurally** safe rather than tuned: both labels sit at the top and grow
*outward* — Tmin's to the left of its line, Tmax's to the right — so no label length can make
them meet. Two earlier layouts failed in ways worth remembering: both at `.top` growing inward
(they met in the middle once the label carried a sentence), and Tmin at `.bottom` (it landed on
the x-axis tick labels).

### Check that a test has teeth

Two of these tests initially passed *with the bug present*. Rendering the chart and OCR-ing it is
only useful if the assertion actually distinguishes the broken layout from the good one, so
every visual assertion here was verified by reintroducing the defect and watching it fail:

| Reintroduced defect | Test that must fail |
|---|---|
| Tmin annotation at `.bottom` (on the axis labels) | `testThresholdLabelsStayInTheTopMargin` |
| Tmin growing inbound with the long sentence (the original overlap) | `testThresholdLabelsDoNotOverlapWhenTminApproachesTmax` |

Three things that made the difference, all learned the hard way:

- **Render at the size the app really uses.** A roomy 700 pt chart hid the original overlap
  completely; the labels only met at the ~480 pt the card actually gets.
- **Prefer position to "does it overlap other text".** OCR *merges* overlapping text and may not
  recognise the thing being overlapped at all, so the overlap check passed while a label sat on
  the axis labels.
- **Assert a margin, not merely "not intersecting".** The original defect was label *growth*, so
  a gap assertion is what catches it coming back.

Two more things that took a round to get right, worth knowing if you extend this:

- **Pin the recognition language.** Without it Vision guessed Vietnamese and read "Tmin 50°"
  as "Thốn 50°", so the label could never be matched.
- **Match on the number as well as the name** (`orNumber:`) so one misread character cannot
  silently turn the test into a skip.

Reach for this whenever a defect is "two things are drawn on top of each other" — it is a
system framework, so it needs no third-party tool, and the assertion is about pixels rather
than intentions.

## Known console noise (verified benign)

Two messages appear in Xcode's console that are **not** defects. Both were chased to a
conclusion so nobody has to do it twice.

### `Unable to obtain a task name port right for pid 619: (os/kern) failure (0x5)`

`pid 619` is **WindowServer** (`_windowserver`). The line comes from
`com.apple.BaseBoard:Common` — AppKit's own app-lifecycle service — logging at *Error* level
that it could not obtain a task *name* port for WindowServer. A normal app is not entitled
to inspect a system process, so the query fails, BaseBoard logs it and carries on. It has
nothing to do with this codebase (28 occurrences in 45 minutes, all attributed to BaseBoard),
it is emitted whenever window/scene geometry is recomputed — which is why it shows up on
navigation — and it cannot be suppressed from application code. Ignore it, or filter the
console on `-subsystem:com.apple.BaseBoard`.

### `[AppKit] Invalid view geometry: width is negative.`

Emitted when the **Settings** screens are laid out (4 lines per render; `testSettingsViewRenders`
and `testContentViewRendersEachSection` show them). It is an AppKit log line only — the layout
renders correctly, every test passes, and no user-visible defect has been traced to it.

It was **not** isolated to a widget. These were all laid out in isolation and did **not**
reproduce it:

| Control experiment | Result |
|---|---|
| `Text("hello")` | clean |
| Minimal grouped `Form` (+ `Section`, `TextField`) | clean |
| The same Form made tall enough to scroll (30 sections) | clean |
| `Picker` with `ForEach(allCases)` in a grouped Form | clean |
| Four `Toggle`s in a grouped Form | clean |
| Slider + fixed-width text + `LabeledContent` + wrapping caption in a grouped Form | clean |
| Three `Section`s in a grouped Form | clean |
| `@AppStorage`-backed `Toggle`/`Slider`/`Picker` in a grouped Form | clean |

It reproduces only with the real `general` / `fanControl` / `about` tab bodies, so something
about their combination is responsible. Whoever isolates it next: render
`SettingsView().general` in `ViewRenderingTests`' harness and count
`grep -c 'Invalid view geometry'` in the xcodebuild output; the tab-level bisect divides it
into three equal thirds.

## Manual smoke test (5 minutes, any Mac)

1. Launch the app. The menu-bar icon appears; no Dock icon unless enabled in Settings.
2. Menu-bar icon → **Open AutoFansMac…** opens the window, **Settings…** opens it on the
   Settings page, and `⌘O` / `⌘,` do the same. With the window already open, the same items
   must front it rather than open a second one.
3. **Settings → Show AutoFansMac in the Dock**: turning it off removes the Dock tile and
   leaves the window open; turning it on brings the tile back. Neither direction closes or
   hides the window.
4. **Sensors** shows temperatures for CPU, GPU, battery and system, grouped and searchable.
   The °C/°F toggle changes every value; *Rescan* re-enumerates.
5. **Fans** lists each fan with Min/Current/Max and an `Auto (macOS)` badge.
6. **Settings → Install helper**: one admin prompt; status flips to *Installed*.
7. Set a fan to **Constant** and raise it above idle: the RPM readout and the fan itself
   should follow. The badge reads `Custom (AutoFansMac)`.
8. Switch to **Full Blast**: both fans go to `F%dMx`.
9. Switch to **Automatic**: both fans return to macOS control and the badge reads `Auto`.
10. Quit the app: fans are restored to Automatic as part of termination.
11. Relaunch: the previous session ended cleanly, so no recovery prompt appears.
12. **Settings → About → Check Now** ends in *Up to date (…)*, *No releases published yet*,
    or a newer release with a *Download* button — the only network request the app makes,
    and the toggle above it switches the automatic daily check off.

If step 4 fails with "a daemon is registered but not responding", the daemon is crashing
rather than missing. Check it directly:

```sh
Scripts/dev-install-helper.sh status          # state, crash count, last exit reason
launchctl print system/com.autofansmac.AutoFansMac.helper | grep -E "state|crash|exit"
```

A climbing `successive crashes` with `last exit reason = OS_REASON_DYLD` means the binary
cannot load its libraries — reinstall after a clean build (see Docs/README-DEV.md,
"Packaging constraints").

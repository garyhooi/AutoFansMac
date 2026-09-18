# AutoFansMac — developer guide

## Layout

```
Packages/SMCKit/          All hardware logic. No UI. SwiftPM, `swift test` works.
  Sources/SMCKit/         types, codecs, IOKit connection, fan probing, unlock FSM,
                          sensor catalog (generated) + scanner, MockSMC
  Tests/SMCKitTests/      38 tests: struct offsets, codec vectors, the 5 unlock scenarios

Helper/                   The privileged launchd daemon (root). Xcode tool target.
Shared/                   The XPC contract, compiled into BOTH app and helper.

AutoFansMac/              The SwiftUI app.
  Models/                 Profile, FanSetting, settings keys
  Services/               SensorService, FanService, CurveEngine, ProfileStore,
                          HelperClient, SafetyMonitor, DiagnosticsLog, AppEnvironment,
                          DockVisibility, MainWindow (window presentation/window tests),
                          UpdateChecker + GitHubReleases (the only network call)
  Views/                  Sensors, Fans, Profiles, Settings, Diagnostics, MenuBar, Onboarding
AutoFansMacTests/         113 tests: curve table, profiles/migration, safety, clamping,
                          helper availability, the update check, a view-rendering harness

Tools/afmctl/             Hardware QA CLI (SwiftPM, links SMCKit)
Support/                  LaunchDaemon plist, entitlements, licences
Scripts/                  build / test / sign / notarize / DMG / unsigned DMG / dev helper install
Docs/                     this file, TESTING.md, COMPATIBILITY.md
```

Source files are picked up through **file-system-synchronized groups**, so adding a
`.swift` file to `AutoFansMac/`, `Helper/` or `Shared/` requires no project edit.
`Shared/` is a member of both targets — that is deliberate, the XPC protocol must be
byte-identical on both sides. The SMCKit package is a local Swift package reference
(`Packages/SMCKit`) linked by the app, the helper and the test bundle.

## Build

```sh
# Fast loop: the hardware layer only, no Xcode project needed
cd Packages/SMCKit && swift test

# Everything, including the app and its tests
xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Debug build
xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Debug test
# 120 tests total: 42 in SMCKitTests (SwiftPM), 78 in AutoFansMacTests

# Or: Scripts/test.sh   (both suites)
```

`Scripts/test.sh` builds into a scratch derived-data directory
(`$TMPDIR/autofansmac-tests/DerivedData`) instead of yours, on purpose: codesign fails with
*"Command CodeSign failed with a nonzero exit code"* when the app is already running from
Xcode's DerivedData, and a test run must not overwrite the build products of the app you are
about to debug. Override with `TEST_DERIVED_DATA=…` if you would rather it reused a cache.
Plain `xcodebuild … test` still uses your DerivedData, so quit the app first.

The first `xcodebuild` in a clean checkout may need package resolution once:

```sh
xcodebuild -project AutoFansMac.xcodeproj -resolvePackageDependencies
```

### Signing

The project uses automatic signing with `DEVELOPMENT_TEAM = 93WWDR82K2`. Replace the team
in three places when you re-badge it:

| Where | Setting |
|---|---|
| `AutoFansMac.xcodeproj` | `DEVELOPMENT_TEAM` (project + all three targets) |
| `Shared/HelperProtocol.swift` | `HelperConstants.teamIdentifier`, and the three bundle ids |
| `Support/com.autofansmac.AutoFansMac.helper.plist` | `Label`, `MachServices` key |

`HelperConstants.teamIdentifier` is what the daemon checks a connecting client's code
signature against, so a mismatch means the helper refuses every connection.

## Troubleshooting: the helper is running but the app says "not responding"

Check the daemon first — `launchctl print system/com.autofansmac.AutoFansMac.helper` reporting
`state = running` does **not** mean the app can talk to it:

```sh
log show --last 5m --predicate 'process == "AutoFansMacHelper"' --info | grep -i refused
```

A `REFUSED connection from pid … identifier …` line means the daemon rejected the app's code
signature. The two failure modes are indistinguishable from the app's side — a refused connection
and an absent daemon both look like silence — which is why the daemon logs refusals with
`os.Logger` and `privacy: .public` (`NSLog` redacts strings to `<private>`, hiding exactly the
detail you need).

**Never hardcode the app's bundle identifier in the daemon's requirement.** It was, once, and the
app target's `PRODUCT_BUNDLE_IDENTIFIER` was later changed in Xcode: the daemon then refused every
connection from its own app and fan control stopped with no visible cause. The daemon now
authorises by **signing team**, and pins an exact identifier only when the installer sets
`AUTOFANSMAC_EXPECTED_CLIENT` — which `Scripts/dev-install-helper.sh` derives from the app it is
installing from, so it cannot drift. Verify a requirement against a real signature with:

```sh
codesign --verify -R='anchor apple generic and certificate leaf[subject.OU] = "93WWDR82K2"' /path/to/AutoFansMac.app
```

If you change the app's bundle identifier, reinstall the daemon — the installed plist carries the
identifier pinned at install time.

## Packaging constraints (read before touching Package.swift)

SMCKit is one target with **two products**, and the split is load-bearing — collapse it and
one of the three consumers breaks:

| Consumer | Links | Why |
|---|---|---|
| App | `SMCKit` (**dynamic**) | The hosted test bundle shares it. With a *static* product Xcode refuses to build: "Swift package product 'SMCKit-product' is linked as a static library by 'AutoFansMacTests' and 'AutoFansMac'. This will result in duplication of library code." |
| AutoFansMacTests | `SMCKit` (**dynamic**) | Same image as the app, so the code must not be duplicated into the bundle. |
| AutoFansMacHelper | `SMCKitStatic` (**static**) | The daemon is a *tool* that is copied out of the app bundle into `/Library/PrivilegedHelperTools`. With a dynamic product it carried `@rpath/SMCKit_…_PackageProduct` into `DerivedData/PackageFrameworks` and crash-looped in dyld — launchd reported `successive crashes` with `last exit reason = OS_REASON_DYLD`, and the app could only say "not installed". |

Two consequences that are easy to trip over:

1. **The app's dynamic product must be embedded.** Because `SMCKit` is dynamic, the app
   target has an **Embed Frameworks** copy phase (`dstSubfolderSpec = 10`). Without it the
   Release app builds and runs from DerivedData (where the rpath resolves) but fails to
   launch anywhere else: `Library not loaded: @rpath/SMCKit.framework`.
2. **Guards exist.** `Scripts/dev-install-helper.sh`, `Scripts/package-dmg.sh` and the CI
   `helper-self-contained` job all check that the helper loads nothing outside
   `/usr/lib` and `/System/Library`, and that every non-system library the *app* loads is
   present in `Contents/Frameworks`. Note that `otool -L` prints a `path (architecture):`
   header per slice for fat binaries — the checks filter those out.

If you add another SwiftPM product, give the helper the **static** one.

## Installing the helper during development

There are two supported ways to get a daemon running, and the app now detects either one
by asking over XPC — how the daemon got there does not matter.

### A. SMAppService (the shipping path)

`SMAppService.daemon(plistName:)` requires a signed app **and** a LaunchDaemon plist whose
`ProgramArguments` is an absolute path. That plist ships inside the bundle and points at
`/Applications/AutoFansMac.app`, so this path only works from the canonical location:

1. Build, then copy `AutoFansMac.app` to `/Applications`.
2. Launch it and press **Install helper** (one admin prompt).
3. If macOS says *waiting for approval*, approve it in **System Settings → General →
   Login Items**, then press **Reconnect**.

### B. Scripted daemon (the Xcode path)

When you run from Xcode the app is in `DerivedData`, so the bundled plist cannot apply.
Install the daemon directly instead:

```sh
sudo Scripts/dev-install-helper.sh install
Scripts/dev-install-helper.sh status
Scripts/dev-install-helper.sh uninstall
```

Run each on its own line and keep it free of trailing comments: in `zsh` (the default
interactive shell on macOS) a mid-line `#` is **not** a comment, so pasting
`install   # does a thing` passes `#` and `does` as arguments. The script now rejects
non-existent paths instead of silently using them, but the comment is still not yours to
paste.

Then press **Reconnect** in Settings (or use the button on the banner). The script finds
the newest Debug build under `DerivedData` automatically, or you can pass a path:
`sudo Scripts/dev-install-helper.sh install /path/to/AutoFansMac.app`.

Before copying anything, `install` refuses a helper that links libraries outside
`/usr/lib` and `/System/Library` (see "Packaging constraints" below for why). `status`
reports the same thing for both the installed daemon and the newest build, so you can
tell whether a build is worth installing *without* needing root:

```
--- installed daemon ---
deps:     NOT self-contained — it crashes in dyld; reinstall from a clean build
service:  ... successive crashes = 185, last exit reason = OS_REASON_DYLD

--- newest build ---
deps:     self-contained — safe to install
```

The daemon validates its client by code signature — Apple-anchored, team identifier, and
bundle id from `Shared/HelperProtocol.swift`. A build signed with your team's **Apple
Development** or **Developer ID** certificate (which is what Xcode Run produces) satisfies
that on its own, so nothing else is needed.

Only an **ad-hoc-signed or unsigned** build fails that check. For that case:

```sh
sudo Scripts/dev-install-helper.sh install --allow-untrusted
```

which adds `AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS=1` to the plist. A DEBUG helper honours it;
a Release helper ignores it. Never leave that configuration in place.

### When no daemon is installed

That is a supported state, not an error: the app reads every sensor, shows fans as
`Auto (macOS)`, and skips fan commands entirely rather than logging failures. The banner
reads *Monitoring only* and offers **Reconnect**.

## Three rules this code follows

### 0. Nothing re-renders that should not

Two instances of this rule have already caused user-visible bugs:

- **The menu-bar dropdown must not observe the environment.** `MenuBarExtra`'s `.menu` style
  renders an `NSMenu`, so re-evaluating its content closes an open submenu. `MenuBarModel` is a
  quiet model that only publishes structural changes; `MenuBarView` holds the environment as a
  plain reference for actions. Live values go in the menu-bar *label*, which updates freely.
- **Bounded per-render work.** The curve sensor menu's options come from `SensorService.lastScan`
  (a full-sweep snapshot) rather than the live sample list, which is replaced every poll tick.

### 1. Everything that publishes observable state is `@MainActor`

`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (set in this project) means a plain `Task { }`
inside a **View** runs on the *global* executor. Views therefore use `Task { @MainActor in … }`,
and the services whose `@Published` state drives the UI — `AppEnvironment`, `FanService`,
`ProfileStore` — are marked `@MainActor` so the compiler rejects an off-main write instead of
SwiftUI raising *"Publishing changes from background threads is not allowed"* at runtime.
That failure mode is not cosmetic: the environment re-emits child changes into SwiftUI, so an
off-main publish leaves **the whole app not responding**.

`AppEnvironment.subscribe(_:service:)` is the backstop: if a service ever does publish off-main
it hops to main and logs the offending service name once, so a freeze cannot recur silently.
`SensorService` polls on its own queue and receives fan readings as a pushed, lock-protected
snapshot (`updateFanSnapshot`) rather than calling back into the main-actor `FanService`.

### Two more

Read `Docs/TESTING.md` §"The two SwiftUI rules this codebase must follow" before adding a
view. In short:

1. **Nested `ObservableObject`s do not propagate.** A view holding
   `@EnvironmentObject var env` is invalidated only by `env`'s own `objectWillChange`, so
   `AppEnvironment.observeChildServices()` re-emits every child service's changes. Without
   it the UI shows stale or empty content and looks frozen.
2. **Never mutate observable state from a view callback.** `onChange` handlers and binding
   setters run inside the update; use `deferToNextRunLoop { … }`.

`AutoFansMacTests/ViewRenderingTests` enforces both by laying every screen out for real and
publishing on a timer while it renders.

## Debugging

```sh
# The daemon's own log lines
log stream --predicate 'process == "AutoFansMacHelper"' --level info

# The app's diagnostics ring, without needing the UI: run the binary directly so NSLog
# goes to stderr as well as the unified log.
"$(xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/AutoFansMac.app/Contents/MacOS/AutoFansMac"

# The app's log lines
log stream --predicate 'process == "AutoFansMac"' --level info

# What the hardware actually says, without the app
cd Tools/afmctl
swift run afmctl platform
swift run afmctl fans
swift run afmctl read F0md          # mode key (case matters)
swift run afmctl read F0Tg          # target RPM
swift run afmctl timing             # per-key read cost; flags keys slower than 5 ms
swift run afmctl diag               # the same bundle as Export Diagnostics
sudo swift run afmctl unlock 0      # exercise the unlock sequence, then release
```

`afmctl set`/`auto`/`unlock` need root because the SMC enforces the write privilege. As a
non-root user they will report `kIOReturnNotPrivileged`, which is the expected answer and
not a bug.

## Design notes worth knowing before you edit

- **`SMCKeyData_t` must stay 80 bytes.** The explicit `padding: UInt16` before `result`
  is load-bearing; `SMCTypesTests` asserts every offset. If you reorder fields, fix the
  test first and watch it fail, then make it pass.
- **The SMC status byte is separate from `kern_return_t`.** `IOConnectCallStructMethod`
  returns success while the firmware refuses. Always check `result`.
- **0x87 is not always failure.** A size-mismatch answer on `F%dTg` often means the value
  was applied anyway; `UnlockSequencer` reads the key back before declaring failure.
- **`SMCConnection` serialises everything on one queue.** Never call a public method from
  inside another (`queue.sync` nests into a deadlock). Internal `cachedKeyInfo` exists for
  exactly that reason.
- **Polling is two-tier on purpose.** A full key sweep costs ~1.2 s cold and ~200 ms warm;
  a hot poll of the curve-tracked sensors plus fans costs ~10 ms. The Sensors window flips
  `SensorService.isDetailed` to widen the poll set, which is what keeps idle CPU near 1 %.
- **`MockSMC` models hardware, not just bytes.** It reproduces mode-3 locking, the `Ftst`
  yield delay, lowercase `F0md`, the Intel `FS! ` mask and a fan that never responds —
  that is how the unlock FSM is tested without hardware.

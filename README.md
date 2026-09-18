# AutoFansMac

Native macOS fan control and sensor monitoring for Apple Silicon and Intel Macs.
A SwiftUI menu-bar app that reads every SMC sensor and — through a small privileged
helper — takes fan speeds away from macOS when you ask it to.

No Electron. No kernel extension. No DriverKit. Three local Swift packages and one Xcode
project. The app makes exactly one network request — the GitHub release check — and it can
be switched off.

## What it does

| | |
|---|---|
| **Sensors** | Every temperature the SMC exposes, named from a 200-entry catalog, plus voltage / power / current / fans as secondary groups. Unknown keys are shown with their raw key. |
| **Fans** | Every fan with Min / Current / Max RPM and a mode badge: `Auto (macOS)` or `Custom (AutoFansMac)`. |
| **Constant RPM** | Pin a fan at any speed in its rated range. |
| **Sensor-based** | Ramp between a start temperature and a saturation temperature on any sensor you pick, with a live curve preview. Below the start temperature the fan stays with macOS, which idles it at 0 RPM — AutoFansMac only takes over when the ramp begins. |
| **Profiles** | Unlimited custom profiles plus the built-ins **Automatic** and **Full Blast**, each editable under Profiles (editing a built-in keeps your version as a profile of your own). Switch from the menu bar. |
| **Updates** | Asks GitHub for the latest release once a day, or on demand from About, and offers the newer disk image. The only network request the app makes. |
| **Safety** | Thermal floor override, per-write clamping, dead-man switch, crash recovery, restore-on-quit. |

## Requirements

- macOS 13 Ventura or later (built and tested on macOS 27 / MacBook Pro M5 Pro).
- Xcode 15 or later to build.
- An administrator password **once**, when you install the helper. Reads need no privileges.

## Build and run

```sh
# Hardware layer tests (no Xcode needed)
cd Packages/SMCKit && swift test

# App + helper + app tests
xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Debug build
xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Debug test

# Hardware QA tool
cd Tools/afmctl && swift run afmctl fans
```

Or just open `AutoFansMac.xcodeproj` and hit Run. See [Docs/README-DEV.md](Docs/README-DEV.md)
for the signing and helper-install details, and `Scripts/` for release packaging.

## Distributing

| Way | Command | Recipient has to |
|---|---|---|
| Unsigned, no Apple account | `Scripts/package-unsigned.sh` | clear the quarantine: `xattr -dr com.apple.quarantine /Applications/AutoFansMac.app` |
| Developer ID + notarized | `Scripts/sign-and-notarize.sh`, then `Scripts/package-dmg.sh` | nothing |

Fan control needs the privileged helper either way, and the helper obeys only a client
whose signature carries the signing team. The unsigned build therefore compiles a helper
that skips that check — [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) says what that
trades away, and how to re-badge the app with your own team.

## How control works

Reading SMC sensors works from any unprivileged process, so the app does that in-process.
Writing fan keys does not: the firmware enforces root on `F%dMd`/`F%dmd` and `F%dTg`.
So writes go through `AutoFansMacHelper`, a launchd daemon installed with `SMAppService`
and reachable only over XPC by a client whose code signature matches this team.

What that daemon does when it has control:

1. Puts the fan in manual mode — directly on M1/M2/M5/Intel, and via the `Ftst` unlock
   sequence on M3/M4 where `thermalmonitord` holds fans in system mode.
2. Re-asserts mode and target every 5 s, because `thermalmonitord` reclaims control
   whenever `Ftst` is not held (~4 s idle, ~250 ms under load).
3. Re-applies everything after wake, because the firmware resets `Ftst` across sleep.
4. Gives the fans back after 60 s without a heartbeat from the app.

Everything is probed at runtime — mode-key casing (`F0Md` vs `F0md`), whether `Ftst`
exists, whether `FS! ` exists, and each key's data type. Nothing is assumed from the
machine's generation, because M2 and M3 base models were never verified upstream.

## Safety

These are not optional:

- **Never 0 RPM by default.** `F%dMn`/`F%dMx` are guidelines the firmware ignores; a
  target of 0 stops the fan. Every commanded value is clamped to
  `[max(F%dMn, 500), F%dMx]`. Sending something outside that range requires enabling the
  expert switch, which warns and lasts one session.
- **Thermal floor.** If any CPU/GPU/SOC sensor reaches 95 °C (configurable), every fan is
  driven to maximum regardless of profile, and normal control returns only after
  temperatures fall 10 °C below the floor.
- **Never leave `Ftst` set.** The dead-man switch, the SIGTERM handler and the
  crash-recovery state file all exist so a crash cannot leave the machine with thermal
  management disabled and nobody driving it.
- **Honest failure.** If the firmware refuses manual mode and there is no unlock key, the
  UI says so per fan and offers the diagnostics export. It never pretends a write worked.

## Documentation

| File | Contents |
|---|---|
| [Docs/README-DEV.md](Docs/README-DEV.md) | Building, signing, the dev helper workaround, architecture map |
| [Docs/TESTING.md](Docs/TESTING.md) | Automated suites and the real-hardware checklist |
| [Docs/COMPATIBILITY.md](Docs/COMPATIBILITY.md) | Per-generation behaviour and verification status |
| [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) | Shipping it three ways: from source, unsigned DMG, Developer ID + notarized |
| [Support/LICENSES.md](Support/LICENSES.md) | Attribution (Stats sensor catalog, MIT) and third-party notes |
| `instruction/AutoFansMac/PROMPT.md` | The original specification this implements |

## Licence

MIT — see [LICENSE](LICENSE). Sensor naming data is derived from [Stats](https://github.com/exelban/stats) by
Serhiy Mytrovtsiy (MIT) — see [Support/LICENSES.md](Support/LICENSES.md).

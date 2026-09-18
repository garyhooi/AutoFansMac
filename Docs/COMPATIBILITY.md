# AutoFansMac — compatibility matrix

Verified means observed on real hardware with `afmctl` and/or the app running. Everything
is probed at runtime; the per-generation rows below describe what the probe is expected to
find, not what the code assumes.

## Verification status

| Platform | Example | Sensors | Constant RPM | Curve | Mode key | Unlock path | Status |
|---|---|---|---|---|---|---|---|
| **M5** | MacBook Pro `Mac17,9` (M5 Pro, macOS 27.0) | ✅ 413 values / 3611 keys | ✅ writes signed+verified in code path | ✅ logic tested | **lowercase `F0md`** | **direct** — `Ftst` absent | **✅ verified on hardware** |
| M4 | MacBook Pro M4 Max | ✅ | ✅ (upstream) | ✅ | uppercase `F%dMd` | `Ftst` unlock | ☐ not tested here |
| M3 | MacBook Pro M3 / iMac M3 | ✅ | ✅ (upstream) | ✅ | uppercase `F%dMd` | `Ftst` unlock | ☐ not tested here |
| M2 | — | ✅ | probe | probe | probe | direct, `Ftst` fallback if refused | ☐ unverified upstream and here |
| M1 | MacBook Pro M1/Pro/Max | ✅ | ✅ (upstream) | ✅ | uppercase `F%dMd` | direct | ☐ not tested here |
| M1 fanless | MacBook Air M1 (`FNum == 0`) | ✅ | n/a | n/a | n/a | n/a | ✅ simulated (`MockSMC`, `testFanlessMachineProbesCleanly`) |
| Intel + T2 | iMac19,1, MBP 2018–2020 | ✅ | ✅ (upstream) | verify | uppercase `F%dMd` + `FS! ` | `F%dMd` + `FS! ` bitmask, `fpe2` or `flt` | ☐ not tested here |
| Intel (no T2) | iMac 2013–2017, MBP ≤2015 | ✅ | verify | verify | `F%dMd` | `FS! ` if present | ☐ not tested here |

## Observation: MacBook Pro 18,9 / Mac17,9 with M5 Pro

Recorded 2026-09-17 with `afmctl platform`, `afmctl fans`, `afmctl read`.

```
Model:            Mac17,9   (Apple M5 Pro, 18 cores, 64 GB)
macOS:            27.0 (26A428), arm64
FNum:             2          (Left fan, Right fan)
Mode keys:        F0md / F1md       ← LOWERCASE, confirmed
Ftst:             absent (0x84)     ← confirmed
FS! :             absent            ← confirmed
Unlock style:     direct
Key space:        3611 keys
Fan key types:    F0Ac/F0Mn/F0Mx/F0Tg = flt (4 bytes)
Attributes:       F0md = 0xd0 (readable+writable), F0Tg = 0xd4, F0Mx = 0x85 (read-only)
Idle:             both fans at 0 RPM, F0Mn = 2317, F0Mx = 7826
Sensors:          413 decoded values, 72 keys all-zero (absent on this model)
Read cost:        0.34 ms/key average, no key slower than 5 ms, 274 unreadable keys
```

Both fans reading 0 RPM at idle is expected: only mode 3 (system control) achieves true
0-RPM idling, and that is exactly where an idle Apple Silicon Mac sits.

## Fan behaviour worth knowing

**Fans have inertia, and the software must respect it.** On `Mac17,9` a fan commanded from
0 RPM to its 7826 RPM maximum is still climbing several seconds later:

```
22:44:44.868  applying 2 fan command(s): profile "Full Blast"
     ~4000 RPM about 3 s later
     ~7830 RPM shortly after
```

An earlier build verified a target by asking "has it arrived?" inside a 2 s window, so a
perfectly healthy fan ramp was reported as *"Fan 0 did not respond"* — with an error banner
shown to the user while the fan was audibly speeding up. That is worse than no verification
at all, because it teaches the user to distrust the app.

`UnlockSequencer` now classifies the response three ways:

| Response | Meaning | UI |
|---|---|---|
| `atTarget` | Within tolerance of the commanded RPM | `Custom (AutoFansMac)` |
| `converging` | Moving toward the target — normal while spinning up or coasting down | `Applying…` with "Spinning up toward N RPM", and it settles to Active on its own |
| `stalled` | Never moved at all | `Custom (unresponsive)` — honest, per pitfall #13 |

Responsiveness is proven by **movement**, so a responding fan exits verification in one poll
(≈250 ms) instead of paying the full 3 s window; only a fan that genuinely never budges is
reported as unresponsive.

Minimum and maximum RPM are also only guidelines, and the M5 clamps targets below `F%dMn`
up to the reported minimum — which `converging` covers correctly, since the fan does move.

**A fan at a standstill needs longer than a spinning one.** These fans idle at **0 RPM** while
macOS owns them, and take several seconds to break free. Verification uses a 3 s window for a
fan that is already turning and a 6 s one for a fan starting from rest; with a single window a
healthy spin-up was reported as *"The fan did not move after a 2317 RPM command."*

### Below Tmin the fan is handed back to macOS (deliberate deviation)

PROMPT.md §6.3 says a curve holds `T ≤ Tmin → target = F%dMn`, and §6.7.1 forbids commanding
0 RPM. Taken literally that pins the fans at their minimum (2317 RPM on `Mac17,9`) whenever a
sensor profile is active, even at a cold 40 °C — louder than leaving them alone, since macOS
idles them at **0 RPM**. Observed as *"after I change it to sensor-based, the fans start
immediately even though temperature is lower than Tmin."*

AutoFansMac therefore:

- **below `Tmin`**: sends the fan back to macOS control (`mode 0`) instead of commanding the
  fan's minimum. It never commands 0 RPM — it stops commanding entirely, and macOS is free to
  idle the fan at 0. A 3 °C hysteresis band below `Tmin` prevents flapping at the threshold.
- **at or above `Tmin`**: takes manual control and commands at least `F%dMn`, ramping to
  `F%dMax` at `Tmax`, exactly as specified.
- **`startRPM` set explicitly**: opts out — the fan stays held at that RPM below `Tmin`, which
  is the documented "hold this floor" setting. Nothing in the UI sets it; it is a profile-file
  field.

The fan card says `Auto — below Tmin 50 °C` in that state so it does not look as though the
setting was ignored, and the curve preview draws 0 there instead of the fan's minimum.

## Known limitations

- **M2 and M3 base models were never verified upstream.** The unlock state machine is
  self-discovering (direct write first, `Ftst` only if the firmware refuses), so either
  behaviour is handled — but the first report from such a machine belongs in this table.
- **Some M3/M4 units appear to couple fans** (community reports, never reproduced
  consistently). AutoFansMac commands each fan independently and verifies `F%dAc`; a fan
  that does not follow is shown as *unresponsive*, never silently accepted.
- **Fan coupling under `F%dMn` floors**: whether the firmware's mode-0 minimum differs from
  the reported `F%dMn` is unverified.
- **`F%dTg = 0` genuinely stops the fan.** The default UI path can never send it; the
  expert switch can, after a modal warning, for one session.
- **Extended HID sensors (the IOHIDEventSystem long-name sensors) and IOReport power
  reading are not implemented.** The specification lists them as optional Phase 8
  enhancements; nothing in the UI advertises them, so there is no dead control.

## Reporting a result

Please include the output of **Settings → About → Export Diagnostics…** (or
`afmctl diag`). It contains the model identifier, chip, macOS build, the probed fan keys
with their data types and attributes, the unlock style, and the recent fan-control events —
everything needed to tell "firmware refused" apart from "the tool picked the wrong key".

# AutoFansMac — licences and attribution

## AutoFansMac

MIT Licence.

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## Stats — sensor naming data

The sensor catalog in `Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift` is generated
from the sensor table of **Stats** by Serhiy Mytrovtsiy, used under the MIT Licence.

- Project: https://github.com/exelban/stats
- Copyright © 2019 Serhiy Mytrovtsiy
- Licence: MIT (full text reproduced in the header of the generated file)

Regenerate with `python3 Scripts/generate-sensor-catalog.py`. The generator reads the
reference snapshot under `instruction/research/stats/` and writes the Swift table; the
generated file's header carries the copyright notice, which is the condition the licence
requires for redistribution.

## Research references (facts and behaviour, no code copied)

| Source | What was used |
|---|---|
| [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) | Reverse-engineering results: the `Ftst` unlock mechanism, mode 3 semantics, the per-generation behaviour matrix, the privilege model, the 80-byte struct layout |
| [exelban/stats](https://github.com/exelban/stats) | Cross-checked call patterns, the `FS! ` Intel sequence, retry timings, and the sensor catalog (MIT) |
| [ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge) | Design corroboration: wake re-apply with a 2 s SMC-readiness delay, watchdog, thermal floor, crash recovery |
| [beltex/SMCKit](https://github.com/beltex/SMCKit) | The Swift struct/padding pattern and the reads-unprivileged / writes-root documentation |
| [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC) | `AppleSmc.h` command and result-code constants, per-key attribute bits |
| [Asahi Linux SMC docs](https://asahilinux.org/docs/hw/soc/smc/) | Apple Silicon key schema and float formats |
| CrystalIDEA Macs Fan Control FAQ | Product-behaviour parity: one admin prompt at install, the `kernel_task` symptom, 0-RPM idling |

No source code from these projects is included beyond the MIT-licensed sensor naming table
described above.

## Dependencies

None. AutoFansMac has **zero third-party runtime dependencies**: no SwiftPM remote
packages, no frameworks beyond the system ones (`SwiftUI`, `AppKit`, `IOKit`, `Charts`,
`Security`, `ServiceManagement`). This is a deliberate constraint for reviewability and
notarisation simplicity. The only dependency edges are local: the app, the helper, the
test bundle and `afmctl` all link the local `SMCKit` package.

## Privacy

AutoFansMac makes no network connections of any kind. It reads SMC sensors on this Mac,
writes fan keys through its own local privileged daemon, and stores profiles in
`~/Library/Application Support/AutoFansMac/`. The diagnostics export is written only to a
file you choose.

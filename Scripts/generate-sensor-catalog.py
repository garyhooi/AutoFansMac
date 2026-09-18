#!/usr/bin/env python3
"""Generates Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift.

The sensor-name catalog is seeded from the Stats project's `Modules/Sensors/values.swift`
(https://github.com/exelban/stats, MIT). This script extracts the 200-entry
`SensorsList` table and emits a Swift table so the seed data stays byte-faithful and
can be regenerated when upstream adds keys.

Usage:  python3 Scripts/generate-sensor-catalog.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SOURCE = os.path.join(REPO, "instruction", "research", "stats", "Sensors_values.swift")
DEST = os.path.join(REPO, "Packages", "SMCKit", "Sources", "SMCKit", "SensorCatalogTable.swift")

ENTRY = re.compile(
    r'Sensor\(key: "([^"]+)", name: "([^"]+)", group: \.(\w+), type: \.(\w+), '
    r'platforms: (.+?)(?:, average: true)?\)'
)

# Stats platform tokens -> our per-generation scope bits.
TOKEN_MAP = {
    "intel": "intel",
    "apple": "appleSilicon",
    "m1": "m1",
    "m2": "m2",
    "m3": "m3",
    "m4": "m4",
    "m5": "m5",
}

GROUP_MAP = {
    "CPU": "cpu",
    "GPU": "gpu",
    "system": "system",
    "sensor": "sensor",
    "hid": "hid",
    "unknown": "unknown",
}


def scope_for(platforms: str) -> str:
    """Maps a Stats platform expression to our SensorPlatformScope literal."""
    platforms = platforms.strip()
    if platforms == "Platform.all" or platforms == "Platform.all)":
        return "[.intel, .appleSilicon]"
    if platforms == "Platform.apple":
        return "[.appleSilicon]"
    match = re.match(r"Platform\.(\w+)Gen$", platforms)
    if match:
        token = match.group(1)
        return "[.%s]" % TOKEN_MAP.get(token, "appleSilicon")

    # A list literal: [.intel] / [.m4Pro, .m4Max, .m4Ultra] / [.m1, .m1Pro, .m4Ultra]
    inner = platforms.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    tokens = [t.strip().lstrip(".") for t in inner.split(",") if t.strip()]
    bits = []
    for token in tokens:
        # A variant token like m4Pro/m4Max/m1Ultra belongs to its generation.
        base = re.match(r"(m[1-5]|intel|apple)", token)
        key = TOKEN_MAP.get(base.group(1) if base else token, None)
        if key and key not in bits:
            bits.append(key)
    if not bits:
        bits = ["appleSilicon"]
    return "[" + ", ".join("." + b for b in bits) + "]"


def swift_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    if not os.path.exists(SOURCE):
        print("source not found: %s" % SOURCE, file=sys.stderr)
        return 1

    with open(SOURCE, encoding="utf-8") as handle:
        contents = handle.read()

    start = contents.index("internal let SensorsList")
    body = contents[start:]
    rows = []
    seen = set()
    for key, name, group, type_, platforms in ENTRY.findall(body):
        if key not in seen:
            seen.add(key)
        rows.append((key, name, GROUP_MAP.get(group, "unknown"), type_, scope_for(platforms)))
        # Keep the `average` flag when present on the source line.
    # Second pass so the average flag travels with the entry.
    entries = []
    for line in body.splitlines():
        match = ENTRY.search(line)
        if not match:
            continue
        key, name, group, type_, platforms = match.groups()
        average = ", average: true" in line
        entries.append((key, name, GROUP_MAP.get(group, "unknown"), type_, scope_for(platforms), average))

    lines = []
    lines.append("//")
    lines.append("//  SensorCatalogTable.swift")
    lines.append("//  SMCKit")
    lines.append("//")
    lines.append("//  GENERATED FILE — do not edit by hand.")
    lines.append("//  Regenerate with: python3 Scripts/generate-sensor-catalog.py")
    lines.append("//")
    lines.append("//  Sensor naming data derived from the Stats project")
    lines.append("//  (https://github.com/exelban/stats), MIT License:")
    lines.append("//")
    lines.append("//      Copyright (c) 2019 Serhiy Mytrovtsiy")
    lines.append("//")
    lines.append("//      Permission is hereby granted, free of charge, to any person obtaining a copy")
    lines.append("//      of this software and associated documentation files (the \"Software\"), to deal")
    lines.append("//      in the Software without restriction, including without limitation the rights")
    lines.append("//      to use, copy, modify, merge, publish, distribute, sublicense, and/or sell")
    lines.append("//      copies of the Software, and to permit persons to whom the Software is")
    lines.append("//      furnished to do so, subject to the following conditions:")
    lines.append("//")
    lines.append("//      The above copyright notice and this permission notice shall be included in all")
    lines.append("//      copies or substantial portions of the Software.")
    lines.append("//")
    lines.append("//      THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR")
    lines.append("//      IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,")
    lines.append("//      FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE")
    lines.append("//      AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER")
    lines.append("//      LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,")
    lines.append("//      OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE")
    lines.append("//      SOFTWARE.")
    lines.append("//")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")
    lines.append("/// The seeded key → (name, group, type, platform scope) table.")
    lines.append("public let kSensorCatalogTable: [SensorCatalogEntry] = [")
    for key, name, group, type_, scope, average in entries:
        average_literal = ", average: true" if average else ""
        lines.append(
            '    SensorCatalogEntry(key: "%s", name: "%s", group: .%s, type: .%s, platforms: %s%s),'
            % (swift_string(key), swift_string(name), group, type_, scope, average_literal)
        )
    lines.append("]")
    lines.append("")

    with open(DEST, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    print("wrote %d entries to %s" % (len(entries), DEST))
    return 0


if __name__ == "__main__":
    sys.exit(main())

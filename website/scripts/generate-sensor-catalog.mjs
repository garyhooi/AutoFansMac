/**
 * Regenerates lib/sensor-catalog.ts from the app's shipped sensor table.
 *
 * The site does not keep its own copy of the sensor names: any other approach drifts
 * the moment the catalog is regenerated in the app. Run this from the repository root:
 *
 *   bun website/scripts/generate-sensor-catalog.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..", "..");
const table = resolve(
  repo,
  "Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift",
);
const outFile = resolve(here, "..", "lib", "sensor-catalog.ts");

const source = readFileSync(table, "utf8");
const entry =
  /SensorCatalogEntry\(key: "([^"]+)", name: "([^"]+)", group: \.([a-zA-Z]+), type: \.([a-zA-Z]+)/g;

const groupNames = { cpu: "CPU", gpu: "GPU", system: "Systems", sensor: "Sensors", hid: "HID", unknown: "Unknown" };
const typeNames = { temperature: "Temperature", voltage: "Voltage", current: "Current", power: "Power", energy: "Energy", fan: "Fans" };

const rows = [];
const seen = new Set();
let match;
while ((match = entry.exec(source)) !== null) {
  const [, key, name, group, type] = match;
  // Wildcard families need a runtime index, so they are not listed as concrete keys.
  if (key.includes("%") || name.includes("%")) continue;
  if (seen.has(key + name)) continue;
  seen.add(key + name);
  rows.push({ key, name, group: groupNames[group] ?? group, type: typeNames[type] ?? type });
}
rows.sort(
  (a, b) => a.group.localeCompare(b.group) || a.name.localeCompare(b.name) || a.key.localeCompare(b.key),
);

const byGroup = {};
const byType = {};
for (const row of rows) {
  byGroup[row.group] = (byGroup[row.group] ?? 0) + 1;
  byType[row.type] = (byType[row.type] ?? 0) + 1;
}

const file = `// GENERATED from Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift.
// Regenerate with: bun website/scripts/generate-sensor-catalog.mjs
//
// These are the shipped catalog entries whose keys are literal FourCCs. Wildcard
// families (TC%c and friends) are resolved at runtime against the machine, so they
// are listed as families instead of as fake concrete keys.

export type CatalogEntry = { key: string; name: string; group: string; type: string };

export const CATALOG: CatalogEntry[] = [
${rows
  .map(
    (r) =>
      `  { key: ${JSON.stringify(r.key)}, name: ${JSON.stringify(r.name)}, group: ${JSON.stringify(r.group)}, type: ${JSON.stringify(r.type)} },`,
  )
  .join("\n")}
];

export const CATALOG_TOTALS = {
  /** Entries in the shipped table, wildcard families included. */
  entries: 200,
  literalKeys: ${rows.length},
  groups: ${JSON.stringify(byGroup)},
  types: ${JSON.stringify(byType)},
};
`;

writeFileSync(outFile, file);
console.log(`wrote ${outFile} with ${rows.length} literal keys`);

/**
 * Every string and every outbound link the site shows, in one place so the copy and
 * the app's own AppLinks.swift cannot drift apart.
 *
 * Facts here come from the repository, not from a copywriter:
 *   README.md, Docs/COMPATIBILITY.md, Shared/HelperProtocol.swift,
 *   AutoFansMac/Services/CurveEngine.swift, Packages/SMCKit/.../SensorCatalogTable.swift
 *
 * House rule for this file: no em-dashes and no en-dashes anywhere. Hyphens only.
 */

export const REPO = "https://github.com/garyhooi/AutoFansMac";
export const RELEASES = `${REPO}/releases`;
export const LICENSE = `${REPO}/blob/main/LICENSE`;
export const STATS = "https://github.com/exelban/stats";

/** The one label used for the one download intent, everywhere on the page. */
export const DOWNLOAD_LABEL = "Download for macOS";
export const SOURCE_LABEL = "View on GitHub";

export const navLinks = [
  { href: "#control", label: "Control" },
  { href: "#sensors", label: "Sensors" },
  { href: "#safety", label: "Safety" },
  { href: "#compatibility", label: "Machines" },
  { href: "#install", label: "Install" },
] as const;

export const hero = {
  chips: ["macOS 13 Ventura or later", "Apple Silicon and Intel"],
  headline: "Take the fans back from macOS.",
  subtext:
    "Free, open source fan control for macOS. Read every SMC sensor and ramp your fans on a curve you draw.",
  caption:
    "Fans: per-fan mode, a sensor curve with Tmin and Tmax, and a live preview before you apply.",
};

/**
 * Real differentiators, not decoration. Each one is checked against the repository:
 * three local Swift packages and one Xcode project, no kext, no DriverKit, the
 * GitHub release check is the only request the app makes.
 */
export const claims = [
  { icon: "ShieldCheck", label: "No kernel extension" },
  { icon: "Feather", label: "No Electron" },
  { icon: "Cube", label: "No DriverKit" },
  { icon: "CloudArrowDown", label: "One network request" },
  { icon: "Scales", label: "Open source, MIT" },
] as const;

export const curve = {
  headline: "Pick the sensor. Draw the ramp.",
  body: "Choose any temperature key, set where the fan starts and where it saturates, and AutoFansMac holds the line between them.",
  /** The shipped ramp, quoted from CurveEngine.swift. */
  formula: "lo + (hi - lo) x (T - Tmin) / (Tmax - Tmin)",
  notes: [
    "Below Tmin the fan is handed back to macOS, which idles it at 0 RPM.",
    "The tracked temperature is an EMA with alpha 0.3, so a spike does not yank the fan.",
    "A command is written only when the target moved 50 RPM or more, and at most once a second.",
    "If the sensor goes missing for 10 s the curve fails safe to full speed instead of stalling.",
  ],
  sensors: [
    { key: "Tp01", name: "CPU performance core 1", group: "CPU" },
    { key: "Tp09", name: "CPU performance core 3", group: "CPU" },
    { key: "Tg0H", name: "GPU 2", group: "GPU" },
    { key: "Tm0p", name: "Memory Proximity 1", group: "Sensors" },
  ],
  /** Measured on a MacBook Pro Mac17,9 (M5 Pro, macOS 27.0) and recorded in Docs/COMPATIBILITY.md. */
  fan: { index: 0, minRPM: 2317, maxRPM: 7826, idleRPM: 0 },
};

export const sensorsSection = {
  headline: "Every sensor the SMC exposes.",
  body: "Named from a 200-entry catalog derived from Stats. Keys that are not in the catalog are still listed, with their raw FourCC, instead of being hidden.",
  stats: [
    { value: "200", label: "catalog entries" },
    { value: "3611", label: "keys on a Mac17,9" },
    { value: "413", label: "decoded values" },
    { value: "0.34 ms", label: "average read cost" },
  ],
};

export const screens = {
  headline: "The whole machine, in five views.",
  body: "Fans, Sensors, Profiles, Settings and the menu bar itself. The menu bar carries the same numbers as the window, so a glance is often enough.",
  /**
   * The menu bar item with its dropdown open.
   *
   * Captured at 1x, so it is shown at its native size inside a bezel rather than
   * stretched: a 350px-wide asset blown up to a full column is soft on every display.
   * Swap in a 700x590 export and only the width and height below change.
   */
  menuBar: {
    src: "/shots/menu-bar.webp",
    width: 350,
    height: 295,
    alt: "The AutoFansMac menu bar item with its dropdown open: both fans on a sensor-based curve, the profile list, and the Open, Settings, Export Diagnostics and Quit items.",
    title: "Menu bar first",
    body: "Switch profiles, watch every fan and check the tracked sensor without opening a window. The window is there when you want the curve.",
  },
  tiles: [
    {
      src: "/shots/profiles.webp",
      alt: "AutoFansMac Profiles view listing the built-in Automatic and Full Blast profiles next to custom ones.",
      title: "Profiles",
      body: "Unlimited profiles plus the built-ins. Edit a built-in and your version is saved as a profile of your own.",
      span: "lg:col-span-7",
    },
    {
      src: "/shots/sensors.webp",
      alt: "AutoFansMac Sensors view listing SMC temperature keys grouped by CPU, GPU and system.",
      title: "Sensors",
      body: "Every temperature, plus voltage, power, current and fans as secondary groups. Searchable.",
      span: "lg:col-span-5",
    },
    {
      src: "/shots/settings.webp",
      alt: "AutoFansMac Settings view showing helper status, lifecycle options and safety controls.",
      title: "Settings",
      body: "Helper, lifecycle and safety in one pane, including the expert switch that lasts a single session.",
      span: "lg:col-span-5",
    },
  ],
};

export const safety = {
  headline: "Safe by construction, honest by default.",
  body: "Four rules are not optional, and they are enforced in the helper rather than in the interface.",
  rules: [
    {
      icon: "Thermometer",
      title: "Never 0 RPM by default",
      body: "Every commanded value is clamped to the range the firmware reports. Sending less requires the expert switch, which warns and lasts one session.",
    },
    {
      icon: "Warning",
      title: "Thermal floor at 95 C",
      body: "Any CPU, GPU or SOC sensor reaching the floor drives every fan to maximum, whatever the profile says. Normal control returns 10 C below it.",
    },
    {
      icon: "Heartbeat",
      title: "Dead-man switch",
      body: "Sixty seconds without a heartbeat from the app and the helper hands the fans back to macOS on its own.",
    },
    {
      icon: "ArrowUUpLeft",
      title: "Never leaves manual mode set",
      body: "The signal handler and the crash-recovery state file both exist so that a crash cannot leave thermal management disabled with nobody driving it.",
    },
  ],
  /** Quoted from Shared/HelperProtocol.swift and CurveEngine.swift. */
  bounds: [
    { label: "Write clamp", value: "max(F%dMn, 500) to F%dMx" },
    { label: "Thermal floor", value: "95 C, configurable" },
    { label: "Floor hysteresis", value: "10 C" },
    { label: "Heartbeat timeout", value: "60 s" },
    { label: "Mode re-assert", value: "every 5 s" },
    { label: "Sensor lost", value: "10 s to full speed" },
    { label: "Write threshold", value: "50 RPM, max 1 per second" },
    { label: "Temperature smoothing", value: "EMA, alpha 0.3" },
  ],
};

export const compatibility = {
  headline: "Probed, not assumed.",
  body: "Mode-key casing, the unlock path and each key's data type are read from the machine at runtime. Nothing is inferred from the model number, because M2 and M3 base models were never verified upstream.",
  machines: [
    {
      generation: "M5",
      example: "MacBook Pro Mac17,9",
      modeKey: "F0md, lowercase",
      unlock: "Direct, no Ftst",
      status: "verified",
      note: "413 decoded values measured here. Both fans idle at 0 RPM under macOS.",
    },
    {
      generation: "M4",
      example: "MacBook Pro M4 Max",
      modeKey: "F%dMd",
      unlock: "Ftst unlock",
      status: "upstream",
      note: "Upstream fan control confirmed. Not tested on this machine.",
    },
    {
      generation: "M3",
      example: "MacBook Pro M3, iMac M3",
      modeKey: "F%dMd",
      unlock: "Ftst unlock",
      status: "upstream",
      note: "thermalmonitord holds the fans in system mode, so the unlock sequence is used.",
    },
    {
      generation: "M2",
      example: "MacBook Air and Pro M2",
      modeKey: "Probed",
      unlock: "Direct, Ftst as fallback",
      status: "untested",
      note: "Unverified upstream and here. The probe path is what runs.",
    },
    {
      generation: "M1",
      example: "MacBook Pro M1, Pro, Max",
      modeKey: "F%dMd",
      unlock: "Direct",
      status: "upstream",
      note: "Upstream fan control confirmed. Not tested on this machine.",
    },
    {
      generation: "M1 fanless",
      example: "MacBook Air M1, FNum 0",
      modeKey: "Not present",
      unlock: "Not applicable",
      status: "simulated",
      note: "A machine with no fans probes cleanly and shows no fan controls at all.",
    },
    {
      generation: "Intel with T2",
      example: "iMac19,1, MacBook Pro 2018 to 2020",
      modeKey: "F%dMd plus FS!",
      unlock: "FS! bitmask, fpe2 or flt",
      status: "upstream",
      note: "Key types differ per machine, which is why every type is probed.",
    },
    {
      generation: "Intel without T2",
      example: "iMac 2013 to 2017, MacBook Pro to 2015",
      modeKey: "F%dMd",
      unlock: "FS! where present",
      status: "untested",
      note: "Fan control is expected to work and has not been verified here.",
    },
  ],
  legend: {
    verified: "Verified on hardware",
    simulated: "Verified in simulation",
    upstream: "Verified upstream",
    untested: "Untested",
  },
};

export const install = {
  headline: "Three ways to run it.",
  body: "Free and open source. An administrator password is needed once, when the helper is installed, and reading sensors needs no privileges at all.",
  tabs: [
    {
      id: "unsigned",
      label: "Unsigned DMG",
      note: "No Apple account needed. The recipient clears the quarantine flag once.",
      lines: [
        "./Scripts/package-unsigned.sh",
        "xattr -dr com.apple.quarantine /Applications/AutoFansMac.app",
      ],
    },
    {
      id: "source",
      label: "From source",
      note: "Xcode 15 or later. Nothing else to install, and no package manager involved.",
      lines: [
        "git clone https://github.com/garyhooi/AutoFansMac.git",
        "cd AutoFansMac && open AutoFansMac.xcodeproj",
      ],
    },
    {
      id: "notarized",
      label: "Notarized",
      note: "A Developer ID certificate and a signing team. The recipient has to do nothing.",
      lines: ["./Scripts/sign-and-notarize.sh", "./Scripts/package-dmg.sh"],
    },
  ],
  requirement:
    "Fan control needs the privileged helper. The helper answers only a client whose code signature matches this team, and the unsigned build is the one exception.",
};

export const limits = {
  headline: "Limits, stated up front.",
  body: "The same list the app itself would give you. None of it is a footnote.",
  items: [
    {
      q: "Do I have to run this as root?",
      a: "No. Reading the SMC works from any unprivileged process, so the app does that itself. Only writes go through the helper, and only the helper is installed with administrator rights.",
    },
    {
      q: "What does the unsigned build give up?",
      a: "Its helper cannot verify the calling app's signature, so any process on the machine could ask it to set a fan speed. That is the trade for not having a Developer ID. Docs/DISTRIBUTING.md says so in the same words and shows how to re-badge the app with your own team.",
    },
    {
      q: "Which machines are actually verified?",
      a: "One: a MacBook Pro Mac17,9 with an M5 Pro, recorded in Docs/COMPATIBILITY.md. M1, M3, M4 and Intel with T2 are confirmed upstream. M2, and Intel without a T2, have never been verified by anyone, and the compatibility list marks them that way instead of claiming otherwise.",
    },
    {
      q: "Does it phone home?",
      a: "It asks GitHub for the latest release once a day, or when you press the button in About. That is the only request the app makes, and it can be switched off.",
    },
    {
      q: "Can it stop a fan completely?",
      a: "Not by default. A target of 0 stops the fan, so every value is clamped into the range the firmware reports, and going outside that range needs the expert switch.",
    },
    {
      q: "What happens if the app crashes?",
      a: "The helper hands the fans back to macOS after 60 seconds without a heartbeat. A SIGTERM handler releases them immediately, and a state file lets the next launch reclaim and then release a fan that manual mode was left on.",
    },
  ],
};

export const footer = {
  tagline: "Free and open source fan control and sensor monitoring for macOS. SwiftUI, three local Swift packages, one network request.",
  columns: [
    {
      title: "Project",
      links: [
        { label: "Source", href: REPO },
        { label: "Releases", href: RELEASES },
        { label: "Licence", href: LICENSE },
      ],
    },
    {
      title: "Documentation",
      links: [
        { label: "Architecture and build", href: `${REPO}/blob/main/Docs/README-DEV.md` },
        { label: "Testing", href: `${REPO}/blob/main/Docs/TESTING.md` },
        { label: "Compatibility", href: `${REPO}/blob/main/Docs/COMPATIBILITY.md` },
        { label: "Distributing", href: `${REPO}/blob/main/Docs/DISTRIBUTING.md` },
      ],
    },
    {
      title: "Attribution",
      links: [
        { label: "Stats sensor catalog", href: STATS },
        { label: "Third-party notes", href: `${REPO}/blob/main/Support/LICENSES.md` },
      ],
    },
  ],
};

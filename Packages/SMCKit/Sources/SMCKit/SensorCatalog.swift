//
//  SensorCatalog.swift
//  SMCKit
//
//  Key → friendly name / group / platform lookup, seeded from the Stats sensor table
//  (see `SensorCatalogTable.swift`, generated, MIT attribution preserved).
//
//  Matching supports `%`-wildcard keys (one `%` per character), which is how the
//  source table covers key families such as `TC%c` or `TA%P`. Unknown keys are not an
//  error: they display their raw FourCC in the "Unknown" group so power users keep
//  full visibility (PROMPT.md §4.7).
//

import Foundation

// MARK: - Group / type

public enum SensorGroup: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case system = "Systems"
    case sensor = "Sensors"
    case hid = "HID"
    case unknown = "Unknown"

    public var id: String { rawValue }

    /// Display order in the Sensors view: CPU, GPU, SOC/HID, Storage-ish sensors,
    /// system, then everything unknown last.
    public var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .hid: return 2
        case .sensor: return 3
        case .system: return 4
        case .unknown: return 5
        }
    }
}

public enum SensorType: String, Codable, Sendable, CaseIterable, Identifiable {
    case temperature
    case voltage
    case current
    case power
    case energy
    case fan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .temperature: return "Temperature"
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .power: return "Power"
        case .energy: return "Energy"
        case .fan: return "Fans"
        }
    }

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .voltage: return "V"
        case .current: return "A"
        case .power: return "W"
        case .energy: return "J"
        case .fan: return "RPM"
        }
    }

    /// Section order in the Sensors view.
    public var sortOrder: Int {
        switch self {
        case .temperature: return 0
        case .fan: return 1
        case .voltage: return 2
        case .power: return 3
        case .current: return 4
        case .energy: return 5
        }
    }
}

/// Temperature unit preference (Settings; PROMPT.md §6.1 °C/°F toggle).
public enum TemperatureUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public var shortName: String { self == .celsius ? "Celsius" : "Fahrenheit" }

    /// Converts a Celsius value into this unit.
    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
    }

    /// Converts a value expressed in this unit back to Celsius.
    public func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32.0) * 5.0 / 9.0
    }
}

// MARK: - Platform scope

/// Which machines a catalog entry applies to. A key can mean different things on
/// different generations (`Tp01` on M1 vs M2), so lookups prefer a generation match.
public struct SensorPlatformScope: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let intel = SensorPlatformScope(rawValue: 1 << 0)
    public static let appleSilicon = SensorPlatformScope(rawValue: 1 << 1)
    public static let m1 = SensorPlatformScope(rawValue: 1 << 2)
    public static let m2 = SensorPlatformScope(rawValue: 1 << 3)
    public static let m3 = SensorPlatformScope(rawValue: 1 << 4)
    public static let m4 = SensorPlatformScope(rawValue: 1 << 5)
    public static let m5 = SensorPlatformScope(rawValue: 1 << 6)

    public static let all: SensorPlatformScope = [.intel, .appleSilicon]

    /// The scope describing the running machine.
    public static func scope(for generation: ChipGeneration) -> SensorPlatformScope {
        switch generation {
        case .m1: return [.appleSilicon, .m1]
        case .m2: return [.appleSilicon, .m2]
        case .m3: return [.appleSilicon, .m3]
        case .m4: return [.appleSilicon, .m4]
        case .m5: return [.appleSilicon, .m5]
        case .appleUnrecognised, .unknown: return [.appleSilicon]
        case .intelT2, .intel: return [.intel]
        }
    }

    public func matches(_ other: SensorPlatformScope) -> Bool {
        !intersection(other).isEmpty
    }
}

// MARK: - Catalog entry

public struct SensorCatalogEntry: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let type: SensorType
    public let platforms: SensorPlatformScope
    /// True for keys that participate in the Stats "average" aggregates (core sensors).
    public var average: Bool = false

    public var id: String { key }

    /// `%` is a single-character wildcard.
    public var isPattern: Bool { key.contains("%") }

    public init(
        key: String,
        name: String,
        group: SensorGroup,
        type: SensorType,
        platforms: SensorPlatformScope,
        average: Bool = false
    ) {
        self.key = key
        self.name = name
        self.group = group
        self.type = type
        self.platforms = platforms
        self.average = average
    }
}

// MARK: - Catalog

public enum SensorCatalog {

    /// The full seeded table (200 entries).
    public static var entries: [SensorCatalogEntry] { kSensorCatalogTable }

    private struct Index {
        let exact: [String: [SensorCatalogEntry]]
        let patterns: [SensorCatalogEntry]
    }

    /// Built once, lazily — Swift's `static let` initialisation is thread safe.
    private static let index: Index = {
        var exact: [String: [SensorCatalogEntry]] = [:]
        var patterns: [SensorCatalogEntry] = []
        for entry in kSensorCatalogTable {
            if entry.isPattern {
                patterns.append(entry)
            } else {
                exact[entry.key, default: []].append(entry)
            }
        }
        return Index(exact: exact, patterns: patterns)
    }()

    /// Finds the best catalog entry for a key on this machine.
    ///
    /// Preference order: exact key + generation match → exact key + architecture match
    /// → exact key (any platform) → `%`-pattern + generation match → pattern + arch →
    /// pattern (any). Returns nil only when nothing matches at all.
    public static func entry(for key: String, generation: ChipGeneration) -> SensorCatalogEntry? {
        let hostScope = SensorPlatformScope.scope(for: generation)

        if let candidates = index.exact[key], let best = best(in: candidates, hostScope: hostScope) {
            return best
        }

        let patternMatches = index.patterns.filter { pattern($0.key, matches: key) }
        return best(in: patternMatches, hostScope: hostScope)
    }

    /// Friendly name with the wildcard character substituted (`TC0c` → "CPU core 0").
    public static func name(for key: String, generation: ChipGeneration) -> String? {
        guard let entry = entry(for: key, generation: generation) else { return nil }
        return expand(name: entry.name, pattern: entry.key, key: key)
    }

    /// True when the catalog knows this key on this machine.
    public static func isKnown(_ key: String, generation: ChipGeneration) -> Bool {
        entry(for: key, generation: generation) != nil
    }

    /// Substitutes each `%` in the display name with the character it matched.
    public static func expand(name: String, pattern: String, key: String) -> String {
        guard pattern.contains("%") else { return name }
        var result = ""
        var keyIterator = key.makeIterator()
        for character in name {
            if character == "%", let matched = keyIterator.next() {
                result.append(matched)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `%` matches exactly one character; every other character must be equal.
    public static func pattern(_ pattern: String, matches key: String) -> Bool {
        let patternCharacters = Array(pattern)
        let keyCharacters = Array(key)
        guard patternCharacters.count == keyCharacters.count else { return false }
        for (expected, actual) in zip(patternCharacters, keyCharacters) where expected != "%" && expected != actual {
            return false
        }
        return true
    }

    // MARK: Private

    private static func best(in candidates: [SensorCatalogEntry], hostScope: SensorPlatformScope) -> SensorCatalogEntry? {
        guard !candidates.isEmpty else { return nil }

        // 1. A generation-specific entry for this exact machine.
        let generationBits = hostScope.subtracting([.intel, .appleSilicon])
        if !generationBits.isEmpty,
           let match = candidates.first(where: { !$0.platforms.intersection(generationBits).isEmpty }) {
            return match
        }
        // 2. An architecture-level entry.
        if let match = candidates.first(where: { $0.platforms.intersection(hostScope).isEmpty == false }) {
            return match
        }
        // 3. Anything at all — better a possibly-wrong name than none, and the caller
        //    can still show the raw key alongside it.
        return candidates.first
    }
}

//
//  SensorScanner.swift
//  SMCKit
//
//  Enumerates, classifies, decodes and names every sensor the machine exposes
//  (PROMPT.md §4.7).
//
//  Discovery is deliberately enumerate-then-classify rather than a hardcoded key
//  list: the set of sensors differs per model and per macOS release, so the catalog
//  only supplies *names*, never the set.
//

import Foundation

/// One displayable sensor reading.
public struct SensorSample: Sendable, Equatable, Identifiable, Codable {
    public let key: String
    public let name: String
    public let type: SensorType
    public let group: SensorGroup
    public let dataType: String
    /// The raw decoded value in the sensor's native unit (°C for temperatures).
    public let rawValue: Double
    /// False when the key is not in the catalog (shown in the "Unknown" group).
    public let isKnown: Bool
    public let isComputed: Bool
    public let isFan: Bool
    public let fanIndex: Int?

    public var id: String { key }
    public var unit: String { type.unit }

    /// The area this sensor belongs to for *aggregation* and safety purposes.
    ///
    /// `group` is the display group, and keys the catalog does not know are deliberately shown
    /// under "Unknown" for transparency (PROMPT.md §4.7). This is more inclusive, because the
    /// catalog lags new silicon: on an M5 Pro it names 9 of the ~44 `Tg*` GPU cluster sensors.
    /// An average, a "hottest" and the thermal floor must not be computed from a minority of
    /// the sensors they claim to cover — a hot unnamed `Tg` sensor has to be able to raise the
    /// fans.
    ///
    /// Attribution is intentionally conservative: only families that unambiguously mean CPU or
    /// GPU (`Tp`/`TP`/`Te`/`Tf`/`TC` case variants, `Tg`/`TG`) are claimed. Anything else stays
    /// unknown rather than being guessed into a critical group.
    public var criticalGroup: SensorGroup {
        if group != .unknown { return group }
        guard type == .temperature else { return .unknown }
        let characters = Array(key)
        guard characters.count == 4, characters[0] == "T" else { return .unknown }
        switch characters[1] {
        case "g", "G": return .gpu          // Tg0D… (Apple Silicon GPU), TG0D (Intel GPU)
        case "p", "P": return .cpu          // Tp01… (Apple Silicon CPU cores)
        case "e", "E": return .cpu          // Te05… (M3/M4 efficiency cores)
        case "f", "F": return .cpu          // Tf04… (M3/M4 performance cores)
        case "C", "c": return .cpu          // TC0P/TC%c (Intel CPU)
        default: return .unknown
        }
    }

    public init(
        key: String,
        name: String,
        type: SensorType,
        group: SensorGroup,
        dataType: String,
        rawValue: Double,
        isKnown: Bool,
        isComputed: Bool = false,
        isFan: Bool = false,
        fanIndex: Int? = nil
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.group = group
        self.dataType = dataType
        self.rawValue = rawValue
        self.isKnown = isKnown
        self.isComputed = isComputed
        self.isFan = isFan
        self.fanIndex = fanIndex
    }

    /// The value expressed in the user's preferred unit.
    public func value(in unit: TemperatureUnit) -> Double {
        type == .temperature ? unit.convert(rawValue) : rawValue
    }

    /// Formatted value with its unit symbol.
    public func displayValue(in unit: TemperatureUnit) -> String {
        let value = self.value(in: unit)
        switch type {
        case .temperature:
            return String(format: "%.1f %@", value, unit.symbol)
        case .fan, .current:
            return String(format: "%.0f %@", value, type.unit)
        case .voltage:
            return String(format: "%.3f %@", value, type.unit)
        case .power, .energy:
            return String(format: "%.2f %@", value, type.unit)
        }
    }

    public func converted(to unit: TemperatureUnit) -> SensorSample {
        guard type == .temperature else { return self }
        return SensorSample(
            key: key, name: name, type: type, group: group, dataType: dataType,
            rawValue: unit.convert(rawValue), isKnown: isKnown, isComputed: isComputed,
            isFan: isFan, fanIndex: fanIndex
        )
    }
}

/// Result of one full scan.
public struct SensorScanResult: Sendable {
    public let samples: [SensorSample]
    /// How many keys the SMC reported.
    public let scannedKeyCount: Int
    /// Keys skipped because they read as all-zero (absent on this model).
    public let absentKeys: [String]
    public let duration: TimeInterval
    public let scannedAt: Date

    public init(
        samples: [SensorSample],
        scannedKeyCount: Int,
        absentKeys: [String],
        duration: TimeInterval,
        scannedAt: Date = Date()
    ) {
        self.samples = samples
        self.scannedKeyCount = scannedKeyCount
        self.absentKeys = absentKeys
        self.duration = duration
        self.scannedAt = scannedAt
    }

    public func samples(ofType type: SensorType) -> [SensorSample] {
        samples.filter { $0.type == type }
    }

    public var temperatureSamples: [SensorSample] { samples(ofType: .temperature) }
    public var fanSamples: [SensorSample] { samples(ofType: .fan) }

    /// Temperature samples belonging to the CPU group, excluding computed aggregates.
    public var cpuTemperatures: [SensorSample] {
        temperatureSamples.filter { $0.group == .cpu && !$0.isComputed }
    }

    public var gpuTemperatures: [SensorSample] {
        temperatureSamples.filter { $0.group == .gpu && !$0.isComputed }
    }

    /// Keys the catalog does not know — surfaced in the Unknown group.
    public var unknownKeys: [String] {
        samples.filter { !$0.isKnown && !$0.isComputed }.map(\.key)
    }

    public func sample(forKey key: String) -> SensorSample? {
        samples.first { $0.key == key }
    }
}

public enum SensorScanner {

    public struct Options: Sendable {
        /// Unknown keys are shown by default — transparency beats a tidy list.
        public var includeUnknown = true
        public var includeVoltage = true
        public var includePower = true
        public var includeCurrent = true
        public var includeFans = true
        /// Adds "CPU average", "CPU hottest", "GPU hottest", "Fastest fan".
        public var includeComputed = true
        /// Applies the Stats-proven sanity windows (temp ≤ 0 or > 110 °C, current > 100 A).
        public var hideImplausibleValues = true

        public init() {}
    }

    /// Identifiers for the computed aggregates — stable so profiles and menu-bar
    /// selections survive relaunches.
    public enum ComputedKey {
        public static let cpuAverage = "computed.cpu.average"
        public static let cpuHottest = "computed.cpu.hottest"
        public static let gpuAverage = "computed.gpu.average"
        public static let gpuHottest = "computed.gpu.hottest"
        public static let socHottest = "computed.soc.hottest"
        public static let fastestFan = "computed.fan.fastest"
    }

    /// Scans sensors. Never throws: individual key failures are skipped.
    ///
    /// - Parameter keys: an explicit key list to read, or nil to enumerate everything
    ///   via `#KEY`. The Sensors window passes the full sweep; the background poller
    ///   passes a hot subset so steady-state CPU stays inside the §N6 budget.
    public static func scan(
        _ smc: SMCAccess,
        platform: PlatformInfo = Platform.current(),
        fans: FanHardwareSnapshot? = nil,
        options: Options = Options(),
        keys explicitKeys: [String]? = nil
    ) -> SensorScanResult {
        let started = Date()
        let keys = explicitKeys ?? smc.allKeys()
        var samples: [SensorSample] = []
        var absent: [String] = []

        for key in keys {
            guard let type = classify(key), isEnabled(type, options: options) else { continue }

            guard let reading = smc.read(key) else { continue }
            guard let value = reading.doubleValue else { continue }

            // All-zero payloads mean "sensor absent on this model" for sensors
            // (but 0 is legitimate for FS! / F%dMd — those are not sensors).
            if reading.bytes.allSatisfy({ $0 == 0 }) {
                absent.append(key)
                continue
            }

            guard value.isFinite else { continue }

            if options.hideImplausibleValues, !isPlausible(value, type: type) {
                absent.append(key)
                continue
            }

            let entry = SensorCatalog.entry(for: key, generation: platform.generation)
            let name = entry.map { SensorCatalog.expand(name: $0.name, pattern: $0.key, key: key) }

            if entry == nil, !options.includeUnknown { continue }

            // A key the catalog does not know is filed under Unknown, but its type is
            // still known from its first character, so it lands in the right tab.
            let group = entry?.group ?? .unknown
            let resolvedName = name ?? key

            samples.append(
                SensorSample(
                    key: key,
                    name: resolvedName,
                    type: entry?.type ?? type,
                    group: group,
                    dataType: reading.dataType,
                    rawValue: value,
                    isKnown: entry != nil
                )
            )
        }

        // Fan readings come from the fan layer, not from the sensor key sweep.
        if options.includeFans, let fans {
            for fan in fans.fans {
                samples.append(
                    SensorSample(
                        key: fan.actualKey,
                        name: fan.displayName,
                        type: .fan,
                        group: .sensor,
                        dataType: fan.valueType,
                        rawValue: fan.currentRPM,
                        isKnown: true,
                        isFan: true,
                        fanIndex: fan.index
                    )
                )
            }
        }

        if options.includeComputed {
            samples.append(contentsOf: computedSensors(from: samples))
        }

        samples.sort { lhs, rhs in
            if lhs.type.sortOrder != rhs.type.sortOrder { return lhs.type.sortOrder < rhs.type.sortOrder }
            if lhs.group.sortOrder != rhs.group.sortOrder { return lhs.group.sortOrder < rhs.group.sortOrder }
            if lhs.isComputed != rhs.isComputed { return !lhs.isComputed }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return SensorScanResult(
            samples: samples,
            scannedKeyCount: keys.count,
            absentKeys: absent,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Classification

    /// Classifies a key by its first character: `T` temperature, `V` voltage,
    /// `P` power, `I` current. Fan keys are excluded — they are read via `FanHardware`.
    public static func classify(_ key: String) -> SensorType? {
        guard key.count == 4, let first = key.first else { return nil }
        switch first {
        case "T": return .temperature
        case "V": return .voltage
        case "P": return .power
        case "I": return .current
        default: return nil
        }
    }

    private static func isEnabled(_ type: SensorType, options: Options) -> Bool {
        switch type {
        case .temperature: return true
        case .voltage: return options.includeVoltage
        case .power: return options.includePower
        case .current: return options.includeCurrent
        case .energy: return false
        case .fan: return false
        }
    }

    /// The Stats-proven sanity windows. A temperature at or below 0 °C, above 110 °C,
    /// a current above 100 A or a power above 1000 W is a decoding artefact, not a
    /// reading worth showing.
    public static func isPlausible(_ value: Double, type: SensorType) -> Bool {
        switch type {
        case .temperature: return value > 0 && value <= 110
        case .voltage: return value > 0 && value <= 50
        case .current: return value >= 0 && value <= 100
        case .power: return value >= 0 && value <= 1_000
        case .energy: return value >= 0
        case .fan: return value >= 0 && value <= 30_000
        }
    }

    // MARK: - Computed sensors

    /// Builds the aggregate sensors the curve engine and menu bar like to track
    /// (PROMPT.md §4.7).
    public static func computedSensors(from samples: [SensorSample]) -> [SensorSample] {
        var computed: [SensorSample] = []

        let cpu = samples.filter { $0.type == .temperature && $0.criticalGroup == .cpu && !$0.isComputed }
        if !cpu.isEmpty {
            let values = cpu.map(\.rawValue)
            computed.append(
                SensorSample(
                    key: ComputedKey.cpuAverage,
                    name: "CPU average",
                    type: .temperature,
                    group: .cpu,
                    dataType: "computed",
                    rawValue: values.reduce(0, +) / Double(values.count),
                    isKnown: true,
                    isComputed: true
                )
            )
            computed.append(
                SensorSample(
                    key: ComputedKey.cpuHottest,
                    name: "CPU hottest",
                    type: .temperature,
                    group: .cpu,
                    dataType: "computed",
                    rawValue: values.max() ?? 0,
                    isKnown: true,
                    isComputed: true
                )
            )
        }

        // A modern Apple Silicon GPU reports many cluster sensors, so an average is often a
        // better tracking signal for a curve than the hottest single core.
        let gpu = samples.filter { $0.type == .temperature && $0.criticalGroup == .gpu && !$0.isComputed }
        if !gpu.isEmpty {
            let values = gpu.map(\.rawValue)
            computed.append(
                SensorSample(
                    key: ComputedKey.gpuAverage,
                    name: "GPU average",
                    type: .temperature,
                    group: .gpu,
                    dataType: "computed",
                    rawValue: values.reduce(0, +) / Double(values.count),
                    isKnown: true,
                    isComputed: true
                )
            )
            computed.append(
                SensorSample(
                    key: ComputedKey.gpuHottest,
                    name: "GPU hottest",
                    type: .temperature,
                    group: .gpu,
                    dataType: "computed",
                    rawValue: values.max() ?? 0,
                    isKnown: true,
                    isComputed: true
                )
            )
        }

        // SOC/HID temperature sensors (Apple Silicon extra HID path, when present).
        let soc = samples.filter { $0.type == .temperature && $0.criticalGroup == .hid && !$0.isComputed }
        if let hottest = soc.map(\.rawValue).max() {
            computed.append(
                SensorSample(
                    key: ComputedKey.socHottest,
                    name: "SOC hottest",
                    type: .temperature,
                    group: .hid,
                    dataType: "computed",
                    rawValue: hottest,
                    isKnown: true,
                    isComputed: true
                )
            )
        }

        if let fastest = samples.filter({ $0.isFan }).max(by: { $0.rawValue < $1.rawValue }) {
            computed.append(
                SensorSample(
                    key: ComputedKey.fastestFan,
                    name: "Fastest fan",
                    type: .fan,
                    group: .sensor,
                    dataType: "computed",
                    rawValue: fastest.rawValue,
                    isKnown: true,
                    isComputed: true
                )
            )
        }

        return computed
    }
}

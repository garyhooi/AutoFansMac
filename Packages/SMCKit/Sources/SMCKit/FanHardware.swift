//
//  FanHardware.swift
//  SMCKit
//
//  Fan key probing (PROMPT.md §4.4). Everything here is a *runtime probe*: the mode
//  key casing, the `Ftst` presence, the `FS! ` force mask and each key's data type
//  are discovered from the machine, never assumed from its generation.
//

import Foundation

/// The fan mode as reported by the SMC mode key.
///
/// UI mapping rule (PROMPT.md §4.4): hardware mode `0` **or** `3` → "Auto (macOS)";
/// `1` → "Custom". Mode `3` is the normal Apple Silicon auto state and is NOT an error.
public enum FanHardwareMode: Int, Codable, Sendable, CaseIterable {
    case auto = 0
    case manual = 1
    case legacyForced = 2
    case system = 3
    case unknown = -1

    public init(rawMode: Int) {
        self = FanHardwareMode(rawValue: rawMode) ?? .unknown
    }

    /// True when macOS (not us) owns the fan.
    public var isAutomatic: Bool { self == .auto || self == .system }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (macOS)"
        case .manual: return "Custom (AutoFansMac)"
        case .legacyForced: return "Legacy forced"
        case .system: return "Auto (macOS system mode)"
        case .unknown: return "Unknown"
        }
    }
}

/// One probed fan.
public struct FanDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    /// `F%dMd` or `F%dmd` — probed per machine, not assumed.
    public let modeKey: String
    public let targetKey: String
    public let actualKey: String
    public let minKey: String
    public let maxKey: String
    /// The data type of the RPM keys (`flt ` on Apple Silicon, `fpe2` on older Intel).
    public let valueType: String
    public let valueSize: Int
    /// `F%dMn` — a *guideline*, not a hard floor (firmware accepts 0 RPM).
    public let minRPM: Double
    /// `F%dMx` — a guideline, not a hard ceiling.
    public let maxRPM: Double
    public let currentRPM: Double
    public let hardwareMode: FanHardwareMode
    public let warnings: [String]

    /// "Fan 0" for machines with a single fan or an unreadable name.
    public var displayName: String { name.isEmpty ? "Fan \(index)" : name }

    public init(
        index: Int,
        name: String,
        modeKey: String,
        targetKey: String,
        actualKey: String,
        minKey: String,
        maxKey: String,
        valueType: String,
        valueSize: Int,
        minRPM: Double,
        maxRPM: Double,
        currentRPM: Double,
        hardwareMode: FanHardwareMode,
        warnings: [String]
    ) {
        self.index = index
        self.name = name
        self.modeKey = modeKey
        self.targetKey = targetKey
        self.actualKey = actualKey
        self.minKey = minKey
        self.maxKey = maxKey
        self.valueType = valueType
        self.valueSize = valueSize
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.currentRPM = currentRPM
        self.hardwareMode = hardwareMode
        self.warnings = warnings
    }
}

/// Result of probing the whole fan subsystem.
public struct FanHardwareSnapshot: Codable, Sendable, Equatable {
    public let fanCount: Int
    public let fans: [FanDescriptor]
    /// True when the mode key is lowercase `F%dmd` (observed on M5).
    public let modeKeyIsLowercase: Bool
    /// True when the `Ftst` unlock key exists on this machine.
    public let hasFtst: Bool
    /// True when the Intel `FS! ` force bitmask exists.
    public let hasForceMask: Bool
    /// Expected unlock style. A *hint* — the helper confirms it with real writes.
    public let unlockStyle: UnlockStyle
    public let platform: PlatformInfo
    public let probedAt: Date

    public var hasFans: Bool { fanCount > 0 }

    public init(
        fanCount: Int,
        fans: [FanDescriptor],
        modeKeyIsLowercase: Bool,
        hasFtst: Bool,
        hasForceMask: Bool,
        unlockStyle: UnlockStyle,
        platform: PlatformInfo,
        probedAt: Date
    ) {
        self.fanCount = fanCount
        self.fans = fans
        self.modeKeyIsLowercase = modeKeyIsLowercase
        self.hasFtst = hasFtst
        self.hasForceMask = hasForceMask
        self.unlockStyle = unlockStyle
        self.platform = platform
        self.probedAt = probedAt
    }

    /// Machine-readable capability report for the helper's `capabilities` XPC reply.
    public func capabilitiesJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

public enum FanHardware {

    /// Probes fan keys. Never throws: an unreadable key produces a descriptor with a
    /// warning instead, so a fanless or unusual Mac still monitors fine.
    public static func probe(_ smc: SMCAccess, platform: PlatformInfo = Platform.current()) -> FanHardwareSnapshot {
        let fanCount = smc.readInt("FNum") ?? 0
        let hasFtst = smc.exists("Ftst")
        let hasForceMask = smc.exists("FS! ")

        // Mode key casing is uniform across fans (F0Md/F0md), so probe once.
        let lowercaseModeKey: Bool
        if fanCount > 0 {
            if smc.exists("F0Md") {
                lowercaseModeKey = false
            } else if smc.exists("F0md") {
                lowercaseModeKey = true
            } else {
                lowercaseModeKey = platform.generation == .m5
            }
        } else {
            // No fans: fall back to the generation hint only for reporting.
            lowercaseModeKey = platform.generation == .m5
        }

        var fans: [FanDescriptor] = []
        for index in 0..<max(fanCount, 0) {
            fans.append(probeFan(index, smc: smc, lowercaseModeKey: lowercaseModeKey, platform: platform))
        }

        let unlockStyle: UnlockStyle
        switch platform.generation {
        case .m3, .m4:
            unlockStyle = hasFtst ? .ftstUnlock : .unavailable
        case .intel, .intelT2:
            unlockStyle = .intelForceMask
        case .m1, .m2, .m5, .appleUnrecognised, .unknown:
            unlockStyle = hasFtst ? .ftstUnlock : .direct
        }

        return FanHardwareSnapshot(
            fanCount: fanCount,
            fans: fans,
            modeKeyIsLowercase: lowercaseModeKey,
            hasFtst: hasFtst,
            hasForceMask: hasForceMask,
            unlockStyle: fanCount > 0 ? unlockStyle : .unavailable,
            platform: platform,
            probedAt: Date()
        )
    }

    /// Probes one fan's keys.
    public static func probeFan(
        _ index: Int,
        smc: SMCAccess,
        lowercaseModeKey: Bool,
        platform: PlatformInfo = Platform.current()
    ) -> FanDescriptor {
        var warnings: [String] = []

        let modeKey = lowercaseModeKey ? "F\(index)md" : "F\(index)Md"
        let targetKey = "F\(index)Tg"
        let actualKey = "F\(index)Ac"
        let minKey = "F\(index)Mn"
        let maxKey = "F\(index)Mx"

        // The target key's data type governs how we encode writes.
        let targetInfo = smc.keyInfo(targetKey)
        let actualInfo = smc.keyInfo(actualKey)
        let valueType = targetInfo?.dataType ?? actualInfo?.dataType ?? "flt "
        let valueSize = Int(targetInfo?.dataSize ?? actualInfo?.dataSize ?? 4)

        if targetInfo == nil { warnings.append("\(targetKey) is missing — this fan cannot be commanded.") }
        if actualInfo == nil { warnings.append("\(actualKey) is missing — the current RPM cannot be read.") }

        let minRPM = readRPM(smc, minKey)
        let maxRPM = readRPM(smc, maxKey)
        let currentRPM = readRPM(smc, actualKey)

        if minRPM == nil { warnings.append("\(minKey) unreadable; using 0 as the lower guideline.") }
        if maxRPM == nil { warnings.append("\(maxKey) unreadable; fan limits are unknown.") }
        if let min = minRPM, let max = maxRPM, max < min {
            warnings.append("\(maxKey) (\(Int(max)) RPM) is below \(minKey) (\(Int(min)) RPM).")
        }

        var hardwareMode = FanHardwareMode.unknown
        if let raw = smc.readInt(modeKey) {
            hardwareMode = FanHardwareMode(rawMode: raw)
        } else {
            warnings.append("\(modeKey) unreadable.")
        }

        var name = smc.readString("F\(index)ID") ?? ""
        if name.isEmpty {
            let count = smc.readInt("FNum") ?? 0
            name = count == 2 ? (index == 0 ? "Left fan" : "Right fan") : "Fan \(index)"
        }

        return FanDescriptor(
            index: index,
            name: name,
            modeKey: modeKey,
            targetKey: targetKey,
            actualKey: actualKey,
            minKey: minKey,
            maxKey: maxKey,
            valueType: valueType,
            valueSize: valueSize,
            minRPM: minRPM ?? 0,
            maxRPM: maxRPM ?? 0,
            currentRPM: currentRPM ?? 0,
            hardwareMode: hardwareMode,
            warnings: warnings
        )
    }

    /// Reads a fan RPM key, applying the `flt ` plausibility window.
    private static func readRPM(_ smc: SMCAccess, _ key: String) -> Double? {
        guard let reading = smc.read(key), let value = reading.doubleValue, value.isFinite else { return nil }
        guard value >= 0, value <= 30_000 else { return nil }
        return value
    }
}

/// The byte-mask helpers for the Intel `FS! ` force bitmask (bit per fan).
public enum FanForceMask {
    public static func mask(_ current: UInt16, setting fan: Int, forced: Bool) -> UInt16 {
        guard fan >= 0, fan < 16 else { return current }
        let bit = UInt16(1) << UInt16(fan)
        return forced ? (current | bit) : (current & ~bit)
    }

    public static func isForced(_ mask: UInt16, fan: Int) -> Bool {
        guard fan >= 0, fan < 16 else { return false }
        return mask & (UInt16(1) << UInt16(fan)) != 0
    }
}

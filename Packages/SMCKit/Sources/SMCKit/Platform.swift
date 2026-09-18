//
//  Platform.swift
//  SMCKit
//
//  Best-effort platform identification. Used for diagnostics, for the sensor
//  catalog's platform scoping, and as a *hint* for which unlock style to expect —
//  never as a hardcoded decision, because untested generations (M2/M3) must be
//  discovered by runtime probing (PROMPT.md §4.6).
//

import Foundation
import IOKit

/// Chip generation, parsed from the CPU brand string.
public enum ChipGeneration: String, Codable, Sendable, CaseIterable {
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"
    case appleUnrecognised = "Apple Silicon (unrecognised)"
    case intelT2 = "Intel (T2)"
    case intel = "Intel"
    case unknown = "Unknown"

    public var isAppleSilicon: Bool {
        switch self {
        case .m1, .m2, .m3, .m4, .m5, .appleUnrecognised: return true
        default: return false
        }
    }
}

/// How manual fan control is expected to be achieved on this machine.
public enum UnlockStyle: String, Codable, Sendable {
    /// Direct `F%dMd = 1` / `F%dmd = 1` writes succeed (M1, M5, M2 presumed).
    case direct
    /// Mode writes are refused with 0x82 until `Ftst = 1` (M3/M4).
    case ftstUnlock
    /// Intel/T2: `F%dMd` plus the `FS! ` force bitmask.
    case intelForceMask
    /// Firmware refuses manual control and there is no unlock key to try.
    case unavailable
}

/// Everything we can learn about the host without touching fan keys.
public struct PlatformInfo: Codable, Sendable, Equatable {
    public var modelIdentifier: String
    public var architecture: String
    public var chipName: String
    public var generation: ChipGeneration
    public var macOSVersion: String
    public var macOSBuild: String
    public var isAppleSilicon: Bool
    public var logicalCPUCount: Int
    public var physicalMemoryBytes: UInt64

    public init(
        modelIdentifier: String,
        architecture: String,
        chipName: String,
        generation: ChipGeneration,
        macOSVersion: String,
        macOSBuild: String,
        isAppleSilicon: Bool,
        logicalCPUCount: Int,
        physicalMemoryBytes: UInt64
    ) {
        self.modelIdentifier = modelIdentifier
        self.architecture = architecture
        self.chipName = chipName
        self.generation = generation
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.isAppleSilicon = isAppleSilicon
        self.logicalCPUCount = logicalCPUCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// e.g. "MacBookPro18,1 · Apple M1 Pro · macOS 27.0 (26A428) · arm64"
    public var summary: String {
        "\(modelIdentifier) · \(chipName) · macOS \(macOSVersion) (\(macOSBuild)) · \(architecture)"
    }

    public var diagnosticsDescription: String {
        """
        Model:            \(modelIdentifier)
        Chip:             \(chipName)
        Generation:       \(generation.rawValue)
        Architecture:     \(architecture)
        macOS:            \(macOSVersion) (\(macOSBuild))
        Logical CPUs:     \(logicalCPUCount)
        Memory:           \(ByteCountFormatter.string(fromByteCount: Int64(physicalMemoryBytes), countStyle: .memory))
        """
    }
}

public enum Platform {

    /// The host's platform information. Cheap enough to call repeatedly, but callers
    /// usually cache it once per launch.
    public static func current() -> PlatformInfo {
        let model = sysctlString("hw.model") ?? "Unknown"
        let chip = sysctlString("machdep.cpu.brand_string") ?? model
        let architecture = currentArchitecture()
        let generation = generation(model: model, chip: chip, architecture: architecture)

        return PlatformInfo(
            modelIdentifier: model,
            architecture: architecture,
            chipName: chip,
            generation: generation,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: "")
                .components(separatedBy: " (").first ?? "Unknown",
            macOSBuild: sysctlString("kern.osversion") ?? "Unknown",
            isAppleSilicon: architecture == "arm64",
            logicalCPUCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    public static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Parses the chip generation from the brand string, with the model identifier as
    /// a fallback. Deliberately heuristic: the runtime probes are authoritative.
    public static func generation(model: String, chip: String, architecture: String) -> ChipGeneration {
        if architecture == "arm64" || chip.localizedCaseInsensitiveContains("Apple") {
            let upper = chip.uppercased()
            for (needle, generation) in [
                ("M1", ChipGeneration.m1), ("M2", .m2), ("M3", .m3), ("M4", .m4), ("M5", .m5),
            ] {
                // Match "M5" or "M5 PRO" but not "M50".
                if let range = upper.range(of: needle) {
                    let after = upper[range.upperBound...].first
                    if after == nil || after == " " || after == "," { return generation }
                }
            }
            return .appleUnrecognised
        }

        return isLikelyT2(modelIdentifier: model) ? .intelT2 : .intel
    }

    /// Best-effort T2 detection for Intel Macs. T2 machines are the 2018+ models with
    /// a bridge OS; the model identifier is the only signal available without
    /// enumerating the bridge controller.
    public static func isLikelyT2(modelIdentifier: String) -> Bool {
        // Apple T2 covers MacBookPro15,x+ / 16,x, MacBookAir8,x+, iMac19,x+,
        // iMacPro1,1, Macmini8,1, MacPro7,1.
        let t2Prefixes = ["MacBookPro15,", "MacBookPro16,", "MacBookAir8,", "MacBookAir9,",
                          "iMac19,", "iMac20,", "iMacPro1,", "Macmini8,", "MacPro7,"]
        return t2Prefixes.contains { modelIdentifier.hasPrefix($0) }
    }

    // MARK: - sysctl

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

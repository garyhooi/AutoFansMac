//
//  FanModels.swift
//  AutoFansMac
//
//  UI-side fan model: how a fan is *meant* to be driven (persisted in a profile) and
//  what is actually happening to it right now (session state).
//

import Foundation
import SMCKit

// MARK: - Control mode

/// How the user wants one fan driven (PROMPT.md §6.2).
enum FanControlMode: String, Codable, CaseIterable, Identifiable {
    /// macOS owns the fan.
    case auto
    /// A single constant RPM.
    case constant
    /// RPM derived from a tracked temperature sensor between Tmin and Tmax.
    case sensor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .constant: return "Constant"
        case .sensor: return "Sensor-based"
        }
    }

    var symbolName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .constant: return "dial.medium"
        case .sensor: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// A constant-RPM setting. `"@max"` resolves to the live `F%dMx` at apply time so a
/// profile made on one machine means "as fast as this fan can go" on another.
enum FanRPMSetting: Codable, Equatable {
    case value(Double)
    case maximum

    /// Literal used in the JSON schema.
    static let maximumToken = "@max"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == Self.maximumToken {
            self = .maximum
        } else {
            self = .value(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let rpm): try container.encode(rpm)
        case .maximum: try container.encode(Self.maximumToken)
        }
    }

    func resolved(maxRPM: Double) -> Double {
        switch self {
        case .value(let rpm): return rpm
        case .maximum: return maxRPM
        }
    }
}

/// A point on a piecewise curve. Unused by the v1 linear curve but kept in the schema
/// so v1.1 can add midpoints without a migration (PROMPT.md §6.4).
struct CurvePoint: Codable, Equatable, Identifiable {
    var temperature: Double
    var rpm: Double

    var id: String { "\(temperature)-\(rpm)" }
}

// MARK: - Per-fan profile setting

/// One fan's entry inside a profile. This is the persisted, versioned form.
struct FanSetting: Codable, Equatable, Identifiable {
    var index: Int
    var mode: FanControlMode
    /// Only meaningful for `.constant`.
    var rpm: FanRPMSetting
    /// Tracked sensor for `.sensor` (SMC key or a `computed.*` aggregate).
    var sensorKey: String?
    /// Cached display name so a profile still reads sensibly if the sensor vanishes.
    var sensorName: String?
    /// Ramping starts once the tracked sensor reaches this temperature (°C).
    var minTemp: Double
    /// The fan saturates at max RPM at this temperature (°C).
    var maxTemp: Double
    /// Advanced: RPM held at/below Tmin (defaults to `F%dMn`).
    var startRPM: Double?
    /// Advanced: RPM at/above Tmax (defaults to `F%dMx`).
    var capRPM: Double?
    /// Reserved for v1.1 piecewise curves.
    var points: [CurvePoint]?

    var id: Int { index }

    init(
        index: Int,
        mode: FanControlMode = .auto,
        rpm: FanRPMSetting = .value(0),
        sensorKey: String? = nil,
        sensorName: String? = nil,
        minTemp: Double = 50,
        maxTemp: Double = 80,
        startRPM: Double? = nil,
        capRPM: Double? = nil,
        points: [CurvePoint]? = nil
    ) {
        self.index = index
        self.mode = mode
        self.rpm = rpm
        self.sensorKey = sensorKey
        self.sensorName = sensorName
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.startRPM = startRPM
        self.capRPM = capRPM
        self.points = points
    }

    static func auto(_ index: Int) -> FanSetting {
        FanSetting(index: index, mode: .auto, rpm: .value(0))
    }

    /// True when applying this sensor/temperature pair would actually change something.
    ///
    /// This is the circuit breaker against the redraw→command→publish feedback loop: the fan
    /// card re-applies its curve whenever the sensor picker reports a change, and a re-render
    /// can look like a change. Re-applying an identical curve must be a no-op, or the loop
    /// runs at ~30 Hz with a real XPC round trip per iteration.
    func differsFromCurve(sensorKey: String, minTemp newMin: Double, maxTemp newMax: Double) -> Bool {
        guard mode == .sensor else { return true }
        if self.sensorKey != sensorKey { return true }
        if abs(self.minTemp - newMin) > 0.001 { return true }
        if abs(self.maxTemp - newMax) > 0.001 { return true }
        return false
    }

    /// True when Tmin/Tmax are usable (validation, PROMPT.md §6.2).
    var hasValidTemperatureRange: Bool {
        minTemp.isFinite && maxTemp.isFinite && minTemp < maxTemp && minTemp >= 0 && maxTemp <= 110
    }
}

// MARK: - Runtime fan state

/// What is happening to one fan right now: probed hardware plus the last command result.
struct FanState: Identifiable, Equatable {
    var descriptor: FanDescriptor
    /// Which profile setting currently governs this fan.
    var setting: FanSetting
    var commandState: FanCommandStatus.State
    /// Human-readable reason when something went wrong.
    var message: String?
    /// RPM we last asked for (nil in auto mode).
    var targetRPM: Double?
    /// True while the safety monitor is overriding the profile for this fan.
    var isSafetyOverride: Bool

    var id: Int { descriptor.index }
    var index: Int { descriptor.index }
    var name: String { descriptor.displayName }
    var mode: FanControlMode { setting.mode }

    /// The badge text shown on the fan card.
    var statusText: String {
        if isSafetyOverride { return "Thermal override" }
        // A sensor curve below its start temperature leaves the fan to macOS on purpose, so
        // "Auto" alone would look like the setting was ignored.
        if setting.mode == .sensor, descriptor.hardwareMode.isAutomatic {
            return "Auto — below Tmin \(Int(setting.minTemp)) °C"
        }
        switch commandState {
        case .idle: return descriptor.hardwareMode.isAutomatic ? "Auto (macOS)" : "Custom (pending)"
        case .applying: return "Applying…"
        case .active: return "Custom (AutoFansMac)"
        case .unresponsive: return "Custom (unresponsive)"
        case .failed: return "Custom (failed)"
        }
    }

    var statusIsProblem: Bool {
        commandState == .failed || commandState == .unresponsive
    }
}

// MARK: - Safety override modes

/// How the safety monitor is allowed to intervene.
enum SafetyOverrideAction: String, Codable {
    case none
    case maximumRPM
}

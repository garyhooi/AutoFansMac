//
//  SafetyMonitor.swift
//  AutoFansMac
//
//  The always-on guard rails of PROMPT.md §6.7.2.
//
//  If any CPU/GPU/SOC temperature reaches the thermal floor (default 95 °C) — or macOS
//  reports a serious thermal state — every fan is commanded straight to `F%dMx`,
//  bypassing whatever profile is active, and the user is told. Normal profile behaviour
//  only resumes once every hot sensor has fallen `hysteresis` degrees below the floor,
//  so the machine does not oscillate at the threshold.
//
//  This is deliberately independent of the profile engine: a bad curve, a lost sensor or
//  a user mistake must not be able to cook the machine.
//

import Foundation
import SMCKit

final class SafetyMonitor: ObservableObject {

    enum State: Equatable {
        case normal
        /// Threshold reached; fans are being forced to maximum.
        case override(trigger: String, peakTemperature: Double)
        /// Recovering: waiting for hysteresis before handing back to the profile.
        case recovering(peakTemperature: Double)

        var isOverriding: Bool {
            if case .override = self { return true }
            return false
        }

        var displayName: String {
            switch self {
            case .normal: return "Normal"
            case .override(let trigger, let peak): return "Thermal override — \(trigger) at \(Int(peak)) °C"
            case .recovering(let peak): return "Recovering from \(Int(peak)) °C"
            }
        }
    }

    @Published private(set) var state: State = .normal
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// Set when `kernel_task` behaviour suggests macOS is throttling defensively
    /// (PROMPT.md §4.8 / §6.7 hint).
    @Published private(set) var throttlingHintVisible = false

    private let log: DiagnosticsLog
    private var thermalStateObserver: NSObjectProtocol?
    private var peakTemperature: Double = 0

    init(log: DiagnosticsLog) {
        self.log = log
    }

    // MARK: - Lifecycle

    func start() {
        thermalState = ProcessInfo.processInfo.thermalState
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.thermalState = ProcessInfo.processInfo.thermalState
            self.log.info("safety", "thermal state changed to \(Self.describe(self.thermalState))")
        }
        log.info("safety", "thermal floor \(Int(AppSettings.thermalFloorCelsius)) °C, "
                 + "enabled=\(AppSettings.thermalFloorEnabled), "
                 + "thermalState override=\(AppSettings.thermalStateOverrideEnabled)")
    }

    func stop() {
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
            self.thermalStateObserver = nil
        }
    }

    // MARK: - Evaluation

    /// The hottest CPU/GPU/SOC temperature in the sample set, or nil when there is none.
    ///
    /// Uses `criticalGroup` rather than the display `group`: an unnamed sensor still has to be
    /// able to trigger the floor. The catalog lags new silicon (on an M5 Pro it names 9 of the
    /// ~44 `Tg*` GPU sensors) and the excluded ones are exactly the kind that get hot.
    func hottestCriticalTemperature(in samples: [SensorSample]) -> (temperature: Double, key: String)? {
        let criticalGroups: Set<SensorGroup> = [.cpu, .gpu, .hid]
        let candidates = samples.filter {
            $0.type == .temperature
                && !$0.isComputed
                && criticalGroups.contains($0.criticalGroup)
                && $0.rawValue > 0
                && $0.rawValue <= SafetyBounds.maximumPlausibleTemperature
        }
        guard let hottest = candidates.max(by: { $0.rawValue < $1.rawValue }) else { return nil }
        return (hottest.rawValue, hottest.key)
    }

    /// Decides what should happen this tick.
    ///
    /// Returns `true` when the caller must force all fans to maximum, `false` when it
    /// must stop overriding (the caller then re-applies the active profile).
    func evaluate(samples: [SensorSample]) -> Decision {
        let floor = AppSettings.thermalFloorCelsius
        let hottest = hottestCriticalTemperature(in: samples)

        let thermalSerious = AppSettings.thermalStateOverrideEnabled
            && (thermalState == .serious || thermalState == .critical)

        var trigger: String?
        if let hottest, hottest.temperature >= floor, AppSettings.thermalFloorEnabled {
            trigger = "\(hottest.key) reached \(String(format: "%.1f", hottest.temperature)) °C"
        } else if thermalSerious {
            trigger = "macOS reported a \(Self.describe(thermalState)) thermal state"
        }

        // The kernel_task hint: a serious thermal state while a custom profile is running
        // is the documented symptom of a curve that is too weak.
        let wasThrottling = throttlingHintVisible
        throttlingHintVisible = thermalSerious
        if throttlingHintVisible, !wasThrottling {
            log.warning("safety", "macOS is throttling (thermal state \(Self.describe(thermalState))); "
                        + "if a custom profile is active its curve may be too weak")
        }

        switch state {
        case .normal:
            if let trigger {
                peakTemperature = hottest?.temperature ?? peakTemperature
                state = .override(trigger: trigger, peakTemperature: peakTemperature)
                log.failure("safety", "THERMAL FLOOR REACHED — forcing all fans to maximum (\(trigger))")
                return .engageMaximum(trigger: trigger)
            }
            return .none

        case .override(let trigger, let peak):
            if let hottest { peakTemperature = max(peak, hottest.temperature) }
            // Stay engaged while anything is at or above floor − hysteresis, or while
            // macOS still reports a serious state.
            let ceiling = floor - SafetyBounds.thermalFloorHysteresis
            let stillHot = (hottest?.temperature ?? 0) >= ceiling
            if stillHot || thermalSerious {
                state = .override(trigger: trigger, peakTemperature: peakTemperature)
                return .none
            }
            state = .recovering(peakTemperature: peakTemperature)
            log.warning("safety", "temperature fell to \(String(format: "%.1f", hottest?.temperature ?? 0)) °C — "
                        + "keeping maximum until \(Int(ceiling)) °C, then restoring the profile")
            return .none

        case .recovering(let peak):
            let ceiling = floor - SafetyBounds.thermalFloorHysteresis
            if let hottest, hottest.temperature >= floor {
                peakTemperature = max(peak, hottest.temperature)
                state = .override(trigger: "\(hottest.key) back at \(String(format: "%.1f", hottest.temperature)) °C",
                                  peakTemperature: peakTemperature)
                log.failure("safety", "temperature rose again — re-engaging the thermal override")
                return .engageMaximum(trigger: "temperature rose again")
            }
            if (hottest?.temperature ?? 0) <= ceiling, !thermalSerious {
                state = .normal
                log.applied("safety", "thermal override released at \(String(format: "%.1f", hottest?.temperature ?? 0)) °C "
                            + "(peak \(Int(peak)) °C); restoring the active profile")
                return .releaseOverride
            }
            state = .recovering(peakTemperature: peak)
            return .none
        }
    }

    enum Decision: Equatable {
        case none
        case engageMaximum(trigger: String)
        case releaseOverride
    }

    /// Forces the monitor back to normal (used when the user switches to Automatic).
    func reset() {
        if state != .normal {
            log.info("safety", "thermal override cleared")
        }
        state = .normal
        peakTemperature = 0
    }

    // MARK: - Helpers

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

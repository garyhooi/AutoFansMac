//
//  CurveEngine.swift
//  AutoFansMac
//
//  The exact ramp math of PROMPT.md §6.3, plus the fail-safes:
//
//      T   = EMA(α=0.3) of the tracked sensor        // smooth spikes; reset on change
//      lo  = startRPM ?? F%dMn ; hi = capRPM ?? F%dMx
//      T ≤ Tmin        → lo
//      T ≥ Tmax        → hi
//      otherwise       → lo + (hi − lo) × (T − Tmin) / (Tmax − Tmin)
//      clamp to [lo, hi] and to the global safety clamp
//      write only when |target − lastApplied| ≥ Δ (default 50 RPM) and ≥ 1 s elapsed
//
//  Sensor lost for more than 10 s while its curve is active → fail-safe to `hi` and
//  flag the curve, exactly as specified. Decreasing temperature walks back down the
//  same line, so the ramp is symmetric.
//

import Foundation
import SMCKit

/// A pure, testable evaluation of one curve. Kept free of side effects so the table
/// tests in SMCKitTests-style form can drive every branch.
struct CurveEvaluation: Equatable {
    var targetRPM: Double
    var smoothedTemperature: Double
    var startRPM: Double
    var capRPM: Double
    /// True when the tracked sensor had no fresh reading.
    var sensorLost: Bool

    static func == (lhs: CurveEvaluation, rhs: CurveEvaluation) -> Bool {
        abs(lhs.targetRPM - rhs.targetRPM) < 0.001
            && abs(lhs.smoothedTemperature - rhs.smoothedTemperature) < 0.001
            && lhs.sensorLost == rhs.sensorLost
    }
}

enum CurveMath {

    /// Exponential moving average factor from the spec.
    static let emaAlpha = 0.3

    /// Smoothes a raw sample.
    static func ema(previous: Double?, sample: Double, alpha: Double = emaAlpha) -> Double {
        guard let previous, previous.isFinite else { return sample }
        return alpha * sample + (1 - alpha) * previous
    }

    /// The ramp itself (no clamping, no side effects).
    static func targetRPM(
        temperature: Double,
        minTemp: Double,
        maxTemp: Double,
        startRPM: Double,
        capRPM: Double
    ) -> Double {
        let lo = startRPM
        let hi = capRPM
        guard hi > lo else { return lo }
        guard maxTemp > minTemp else { return temperature >= maxTemp ? hi : lo }

        if temperature <= minTemp { return lo }
        if temperature >= maxTemp { return hi }
        let fraction = (temperature - minTemp) / (maxTemp - minTemp)
        return lo + (hi - lo) * fraction
    }

    /// Evaluates a full curve for one fan.
    static func evaluate(
        setting: FanSetting,
        fan: FanDescriptor,
        temperature: Double?,
        previousSmoothed: Double?,
        sensorLost: Bool
    ) -> CurveEvaluation {
        let lo = setting.startRPM ?? max(fan.minRPM, SafetyBounds.absoluteMinimumRPM)
        let hi = setting.capRPM ?? (fan.maxRPM > 0 ? fan.maxRPM : lo)

        guard let temperature, !sensorLost else {
            // Fail-safe: a lost sensor raises the fan rather than leaving it unsupported.
            return CurveEvaluation(targetRPM: hi, smoothedTemperature: previousSmoothed ?? 0,
                                   startRPM: lo, capRPM: hi, sensorLost: true)
        }

        let smoothed = ema(previous: previousSmoothed, sample: temperature)
        let target = targetRPM(
            temperature: smoothed,
            minTemp: setting.minTemp,
            maxTemp: setting.maxTemp,
            startRPM: lo,
            capRPM: hi
        )
        return CurveEvaluation(targetRPM: target, smoothedTemperature: smoothed,
                               startRPM: lo, capRPM: hi, sensorLost: false)
    }
}

/// Runtime per-fan curve bookkeeping.
private struct CurveRuntime {
    var smoothedTemperature: Double?
    var lastAppliedRPM: Double?
    var lastAppliedAt: Date?
    var lastSensorSeenAt: Date?
    var sensorLostReported = false
    /// True while this curve holds the fan in manual mode. Below Tmin the fan is handed back
    /// to macOS instead, which idles it at 0 RPM.
    var engaged = false
}

/// Drives sensor-based fans each poll tick.
final class CurveEngine {

    /// How long a curve tolerates a missing sensor before raising the fan.
    static let sensorLostTimeout: TimeInterval = 10

    private var runtime: [Int: CurveRuntime] = [:]
    private var lastTrackedSensor: [Int: String] = [:]
    private let log: DiagnosticsLog

    init(log: DiagnosticsLog) {
        self.log = log
    }

    /// The keys the engine needs fresh values for.
    func trackedSensorKeys(settings: [FanSetting]) -> Set<String> {
        Set(settings.compactMap { $0.mode == .sensor ? $0.sensorKey : nil })
    }

    /// Resets EMA state for a fan (used when the tracked sensor changes so a new sensor
    /// does not inherit the old one's smoothing — §6.3).
    func reset(fanIndex: Int) {
        runtime[fanIndex] = CurveRuntime()
        lastTrackedSensor.removeValue(forKey: fanIndex)
    }

    func resetAll() {
        runtime.removeAll()
        lastTrackedSensor.removeAll()
    }

    /// How far the tracked temperature must fall below Tmin before the fan is handed back to
    /// macOS. Without it the fan would flap between macOS control and manual mode right at the
    /// threshold.
    static let releaseHysteresisCelsius: Double = 3

    /// One tick. Returns the fan indices that were written to.
    ///
    /// Below Tmin the fan is **released to macOS control** rather than pinned at `F%dMn`:
    /// on Apple Silicon macOS idles a fan at 0 RPM, so "do nothing until it is needed" is both
    /// what a user expects from a temperature curve and quieter than holding the fan at its
    /// minimum. An explicit `startRPM` opts out — that is the documented "hold this floor"
    /// setting — and commanding 0 RPM is never part of this path.
    @discardableResult
    func tick(
        settings: [FanSetting],
        fans: [FanDescriptor],
        temperatureProvider: (String) -> Double?,
        writer: (Int, Double) async -> Bool,
        releaser: (Int) async -> Bool = { _ in true }
    ) async -> [Int] {
        var written: [Int] = []

        for setting in settings where setting.mode == .sensor {
            guard let key = setting.sensorKey,
                  let fan = fans.first(where: { $0.index == setting.index }) else { continue }

            var state = runtime[setting.index] ?? CurveRuntime()

            // Tracked sensor changed → re-seed the EMA.
            if let previous = lastTrackedSensor[setting.index], previous != key {
                log.info("curve", "fan \(setting.index) now tracks \(key) (was \(previous)); EMA re-seeded")
                state.smoothedTemperature = nil
                state.lastAppliedRPM = nil
                state.sensorLostReported = false
            }
            lastTrackedSensor[setting.index] = key

            let raw = temperatureProvider(key)
            if raw != nil {
                state.lastSensorSeenAt = Date()
                if state.sensorLostReported {
                    log.info("curve", "fan \(setting.index): sensor \(key) is back")
                    state.sensorLostReported = false
                }
            }

            let lost: Bool
            if let lastSeen = state.lastSensorSeenAt {
                lost = Date().timeIntervalSince(lastSeen) > Self.sensorLostTimeout
            } else {
                lost = raw == nil
            }

            let evaluation = CurveMath.evaluate(
                setting: setting,
                fan: fan,
                temperature: raw,
                previousSmoothed: state.smoothedTemperature,
                sensorLost: lost
            )

            if evaluation.sensorLost, !state.sensorLostReported {
                log.failure("curve", "fan \(setting.index): sensor \(key) unreadable for "
                            + "\(Int(Self.sensorLostTimeout)) s — raising fan to \(Int(evaluation.capRPM)) RPM")
                state.sensorLostReported = true
            }

            state.smoothedTemperature = evaluation.smoothedTemperature

            // Below the ramp's start, leave the fan alone (macOS idles it at 0 RPM) unless the
            // user asked for an explicit floor with `startRPM`.
            if !evaluation.sensorLost, setting.startRPM == nil {
                let releaseAt = setting.minTemp - Self.releaseHysteresisCelsius
                if evaluation.smoothedTemperature < releaseAt {
                    if state.engaged {
                        _ = await releaser(setting.index)
                        state.engaged = false
                        state.lastAppliedRPM = nil
                        log.info("curve", "fan \(setting.index): \(String(format: "%.1f", evaluation.smoothedTemperature)) °C "
                                 + "is below Tmin \(Int(setting.minTemp)) °C — handing the fan back to macOS")
                    }
                    runtime[setting.index] = state
                    continue
                }
            }

            let delta = AppSettings.minimumRPMDelta
            let shouldWrite: Bool
            if let last = state.lastAppliedRPM {
                shouldWrite = abs(evaluation.targetRPM - last) >= delta
            } else {
                shouldWrite = true
            }

            if shouldWrite, await writer(setting.index, evaluation.targetRPM) {
                state.engaged = true
                state.lastAppliedRPM = evaluation.targetRPM
                state.lastAppliedAt = Date()
                written.append(setting.index)
            }

            runtime[setting.index] = state
        }

        return written
    }

    /// Snapshot of the engine's view of a fan, for the curve editor's live markers.
    func smoothedTemperature(fanIndex: Int) -> Double? {
        runtime[fanIndex]?.smoothedTemperature
    }

    func lastAppliedRPM(fanIndex: Int) -> Double? {
        runtime[fanIndex]?.lastAppliedRPM
    }

    func isSensorLost(fanIndex: Int) -> Bool {
        runtime[fanIndex]?.sensorLostReported ?? false
    }

    /// True while this curve is holding the fan in manual mode.
    func isEngaged(fanIndex: Int) -> Bool {
        runtime[fanIndex]?.engaged ?? false
    }
}

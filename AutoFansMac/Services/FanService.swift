//
//  FanService.swift
//  AutoFansMac
//
//  Mirror of the hardware fan state (reads, in-process and unprivileged) plus the
//  single place fan commands are issued from (writes, through the helper).
//
//  Two rules from PROMPT.md drive the shape of this type:
//    * §6.7.1 — every commanded target is clamped to [max(F%dMn, 500), F%dMx] unless
//      the expert override is on; a default code path never sends 0 RPM.
//    * §6.7.8 — failures are reported per fan, never swallowed. The UI can always tell
//      "applying", "active", "unresponsive" and "failed" apart.
//

import Foundation
import SMCKit

/// Main-actor isolated on purpose: every `@Published` here feeds the fan cards, and the
/// command path is user/UI driven. `refreshReadings()` writes `states` from wherever it is
/// called, so the type guarantees that is the main actor instead of relying on the caller.
/// The sensor layer's need for fan RPM is served by a pushed snapshot
/// (`SensorService.updateFanSnapshot`), so nothing reaches in from a background queue.
@MainActor
final class FanService: ObservableObject {

    // MARK: - Published state

    /// Probed fan hardware, refreshed every poll.
    @Published private(set) var snapshot: FanHardwareSnapshot
    /// Per-fan UI state (hardware + desired setting + last command result).
    @Published private(set) var states: [FanState] = []
    /// True when the safety monitor is currently overriding profiles.
    @Published private(set) var isSafetyOverrideActive = false
    /// False when no daemon is available, i.e. the app is monitoring only. Kept in sync
    /// by `AppEnvironment` so the UI never shows "Applying…" for a command that cannot
    /// be sent.
    @Published private(set) var isControlAvailable = true

    // MARK: - Dependencies

    private let smc: SMCAccess
    private let helper: HelperClient
    private let log: DiagnosticsLog
    private let queue = DispatchQueue(label: "com.autofansmac.fans", qos: .userInitiated)

    /// The desired settings, one per fan, mirroring the active profile.
    private var settings: [Int: FanSetting] = [:]
    /// Per-fan command status as last reported by the helper.
    private var statuses: [Int: FanCommandStatus] = [:]
    /// Last RPM the curve engine actually sent, to enforce the write-rate limit.
    private var lastSentRPM: [Int: Double] = [:]
    private var lastSentAt: [Int: Date] = [:]

    var platform: PlatformInfo { snapshot.platform }

    init(smc: SMCAccess, helper: HelperClient, log: DiagnosticsLog) {
        self.smc = smc
        self.helper = helper
        self.log = log
        self.snapshot = FanHardware.probe(smc, platform: Platform.current())
    }

    // MARK: - Reads

    /// Re-probes the fan hardware. Cheap (a handful of SMC reads).
    func refreshReadings() {
        let probe = FanHardware.probe(smc, platform: snapshot.platform)

        // Preserve the live command state; only the hardware readings change.
        var newStates: [FanState] = []
        for fan in probe.fans {
            let setting = settings[fan.index] ?? .auto(fan.index)
            let status = statuses[fan.index]
            newStates.append(
                FanState(
                    descriptor: fan,
                    setting: setting,
                    commandState: resolvedCommandState(fan: fan, status: status),
                    message: status?.message,
                    targetRPM: status?.targetRPM,
                    isSafetyOverride: isSafetyOverrideActive
                )
            )
        }

        let hardwareChanged = probe.fanCount != snapshot.fanCount
            || probe.modeKeyIsLowercase != snapshot.modeKeyIsLowercase
        snapshot = probe
        if hardwareChanged {
            log.info("fans", "hardware re-probed: \(probe.fanCount) fan(s), "
                     + "mode key \(probe.modeKeyIsLowercase ? "lowercase" : "uppercase")")
        }

        DispatchQueue.main.async { self.states = newStates }
    }

    /// Derives the visible command state, preferring hardware truth over memory:
    /// after a helper restart or a reboot the hardware may be back in auto.
    private func resolvedCommandState(fan: FanDescriptor, status: FanCommandStatus?) -> FanCommandStatus.State {
        let setting = settings[fan.index] ?? .auto(fan.index)
        if setting.mode == .auto { return .idle }
        // With no daemon nothing was ever sent, so a manual setting is intent, not state.
        if !isControlAvailable { return .idle }
        // A sensor curve below Tmin is deliberately idle: macOS owns the fan until the
        // temperature reaches the ramp's start. That is not a command in flight.
        if setting.mode == .sensor, fan.hardwareMode.isAutomatic { return .idle }
        if fan.hardwareMode.isAutomatic { return .applying }
        switch status?.state {
        case .failed: return .failed
        case .unresponsive: return .unresponsive
        case .active: return .active
        default: return fan.hardwareMode == .manual ? .active : .applying
        }
    }

    /// Told by `AppEnvironment` whenever the helper's availability changes.
    func setControlAvailable(_ available: Bool) {
        guard available != isControlAvailable else { return }
        isControlAvailable = available
        log.info("fans", available
                 ? "fan control is available"
                 : "fan control is unavailable — monitoring only")
        refreshReadings()
    }

    // MARK: - Desired state

    /// Replaces the desired settings (used when a profile is applied).
    func setDesiredSettings(_ newSettings: [FanSetting]) {
        settings = Dictionary(uniqueKeysWithValues: newSettings.map { ($0.index, $0) })
        refreshReadings()
    }

    func setting(for fanIndex: Int) -> FanSetting {
        settings[fanIndex] ?? .auto(fanIndex)
    }

    var desiredSettings: [FanSetting] {
        settings.values.sorted { $0.index < $1.index }
    }

    /// Fans currently meant to be under our control.
    var manualFanIndices: [Int] {
        settings.values.filter { $0.mode != .auto }.map(\.index).sorted()
    }

    // MARK: - Clamping (§6.7.1)

    /// Applies the mandatory safety clamp to a target RPM.
    ///
    /// `F%dMn`/`F%dMx` are guidelines the firmware does not enforce — it happily accepts
    /// 0 RPM and stops the fan — so the clamp is ours to apply.
    func clamp(rpm: Double, fan: FanDescriptor, allowUnsafe: Bool = AppSettings.allowUnsafeFanTargets) -> Double {
        guard rpm.isFinite else { return fan.minRPM }
        if allowUnsafe { return max(0, min(rpm, fan.maxRPM > 0 ? fan.maxRPM * 1.2 : rpm)) }
        let lower = max(fan.minRPM, SafetyBounds.absoluteMinimumRPM)
        let upper = fan.maxRPM > 0 ? fan.maxRPM : lower
        guard upper >= lower else { return lower }
        return min(max(rpm, lower), upper)
    }

    /// True when the requested value had to be clamped (drives the warning colour).
    func isClamped(rpm: Double, fan: FanDescriptor) -> Bool {
        abs(clamp(rpm: rpm, fan: fan) - rpm) > 0.5
    }

    // MARK: - Commands

    /// Issues a full desired fan vector through the helper, then refreshes readings.
    @discardableResult
    func apply(_ payloads: [FanCommandPayload], reason: String) async -> Result<[FanCommandStatus], HelperError> {
        guard !payloads.isEmpty else { return .success([]) }

        log.info("fans", "applying \(payloads.count) fan command(s): \(reason)")
        let result = await helper.applyFanStates(payloads)

        switch result {
        case .success(let statuses):
            for status in statuses {
                self.statuses[status.index] = status
                if status.state == .failed {
                    log.failure("fan \(status.index)", status.message ?? "command failed")
                } else if status.state == .unresponsive {
                    log.warning("fan \(status.index)", status.message ?? "fan did not respond")
                }
            }
            if payloads.contains(where: { $0.mode == .manual }) {
                helper.startHeartbeat()
            }

        case .failure(let error) where error.isPreconditionFailure:
            // "Fan control is not set up yet" is not a command failure. Monitoring-only
            // is a supported state (N7), so record it once as a warning and leave the
            // fans showing as macOS-controlled — which is the truth: nothing was sent.
            log.warning("fans", "fan control unavailable — \(error.localizedDescription)")
            isControlAvailable = false
            for payload in payloads {
                self.statuses[payload.index] = FanCommandStatus(
                    index: payload.index,
                    state: .idle,
                    targetRPM: nil,
                    actualRPM: self.snapshot.fans.first { $0.index == payload.index }?.currentRPM,
                    hardwareMode: .auto,
                    message: "Fan control is off: \(error.localizedDescription)"
                )
            }
            refreshReadings()
            return .failure(error)

        case .failure(let error):
            log.failure("fans", "apply failed: \(error.localizedDescription)")
            // Reflect the failure so the UI does not show a stale "active".
            for payload in payloads {
                self.statuses[payload.index] = FanCommandStatus(
                    index: payload.index,
                    state: .failed,
                    targetRPM: payload.targetRPM,
                    actualRPM: self.snapshot.fans.first { $0.index == payload.index }?.currentRPM,
                    message: error.localizedDescription
                )
            }
        }

        refreshReadings()
        return result
    }

    /// Puts one fan back under macOS control.
    @discardableResult
    func setAuto(fanIndex: Int, reason: String = "user set Auto") async -> Result<[FanCommandStatus], HelperError> {
        settings[fanIndex] = .auto(fanIndex)
        lastSentRPM.removeValue(forKey: fanIndex)
        refreshReadings()
        let result = await apply([.auto(fanIndex)], reason: reason)
        if manualFanIndices.isEmpty { helper.stopHeartbeat() }
        return result
    }

    /// Constant RPM for one fan.
    @discardableResult
    func setConstant(fanIndex: Int, rpm: Double, reason: String = "user set Constant") async -> Result<[FanCommandStatus], HelperError> {
        guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else {
            return .failure(.daemonReported("Fan \(fanIndex) is not present."))
        }
        let clamped = clamp(rpm: rpm, fan: fan)
        if abs(clamped - rpm) > 0.5 {
            log.warning("fan \(fanIndex)", "requested \(Int(rpm)) RPM clamped to \(Int(clamped)) RPM")
        }

        var setting = settings[fanIndex] ?? .auto(fanIndex)
        setting.mode = .constant
        setting.rpm = .value(clamped)
        settings[fanIndex] = setting
        lastSentRPM[fanIndex] = clamped
        lastSentAt[fanIndex] = Date()
        refreshReadings()

        return await apply([.manual(fanIndex, rpm: clamped)], reason: reason)
    }

    /// Full blast for one fan (`F%dMx`).
    @discardableResult
    func setFullBlast(fanIndex: Int) async -> Result<[FanCommandStatus], HelperError> {
        guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else {
            return .failure(.daemonReported("Fan \(fanIndex) is not present."))
        }
        return await setConstant(fanIndex: fanIndex, rpm: fan.maxRPM, reason: "user chose Full blast")
    }

    /// Sensor-based control for one fan.
    @discardableResult
    func setCurve(
        fanIndex: Int,
        sensorKey: String,
        sensorName: String?,
        minTemp: Double,
        maxTemp: Double,
        startRPM: Double? = nil,
        capRPM: Double? = nil
    ) async -> Result<[FanCommandStatus], HelperError> {
        var setting = settings[fanIndex] ?? .auto(fanIndex)
        setting.mode = .sensor
        setting.sensorKey = sensorKey
        setting.sensorName = sensorName
        setting.minTemp = minTemp
        setting.maxTemp = maxTemp
        setting.startRPM = startRPM
        setting.capRPM = capRPM
        settings[fanIndex] = setting
        refreshReadings()
        // The curve engine issues the first target on its next tick.
        return .success([])
    }

    /// Hands one fan back to macOS *without* changing the desired setting — the curve engine
    /// uses this when the tracked temperature is below Tmin, so the fan idles at 0 RPM instead
    /// of being pinned at `F%dMn` for no reason.
    ///
    /// Deliberately not `setAuto`: that would rewrite the profile's sensor setting, and the fan
    /// must come back under the curve as soon as the temperature rises.
    @discardableResult
    func releaseCurveTarget(fanIndex: Int) async -> Bool {
        guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else { return false }
        lastSentRPM.removeValue(forKey: fanIndex)
        lastSentAt.removeValue(forKey: fanIndex)
        // Already macOS-controlled: nothing to send, and no round trip.
        if fan.hardwareMode.isAutomatic { return true }
        let result = await apply([.auto(fanIndex)], reason: "curve below Tmin")
        if case .failure = result { return false }
        return true
    }

    /// Sends an already-computed target (curve engine path), honouring the write-rate
    /// limits in §6.7.7: ≥ 1 s between writes per fan and a material RPM delta.
    @discardableResult
    func sendCurveTarget(fanIndex: Int, rpm: Double, minimumDelta: Double, minimumInterval: TimeInterval) async -> Bool {
        guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else { return false }
        let clamped = clamp(rpm: rpm, fan: fan)

        if let last = lastSentRPM[fanIndex], abs(last - clamped) < minimumDelta {
            return false
        }
        if let lastAt = lastSentAt[fanIndex], Date().timeIntervalSince(lastAt) < minimumInterval {
            return false
        }

        lastSentRPM[fanIndex] = clamped
        lastSentAt[fanIndex] = Date()
        let result = await apply([.manual(fanIndex, rpm: clamped)], reason: "curve target \(Int(clamped)) RPM")
        if case .failure = result { return false }
        return true
    }

    /// Emergency path used by SafetyMonitor: everything to max RPM, bypassing profiles.
    @discardableResult
    func forceMaximumRPM(reason: String) async -> Result<[FanCommandStatus], HelperError> {
        let payloads = snapshot.fans.map { FanCommandPayload.manual($0.index, rpm: $0.maxRPM) }
        guard !payloads.isEmpty else { return .success([]) }
        isSafetyOverrideActive = true
        refreshReadings()
        log.warning("safety", "forcing all fans to maximum: \(reason)")
        return await apply(payloads, reason: "thermal floor override — \(reason)")
    }

    /// Ends a safety override and hands control back to the active profile.
    func endSafetyOverride() {
        guard isSafetyOverrideActive else { return }
        isSafetyOverrideActive = false
        lastSentRPM.removeAll()
        lastSentAt.removeAll()
        refreshReadings()
    }

    /// Restores every fan to macOS control.
    @discardableResult
    func restoreAllToAuto(reason: String) async -> Result<Void, HelperError> {
        log.info("fans", "restoring all fans to automatic: \(reason)")
        lastSentRPM.removeAll()
        lastSentAt.removeAll()
        statuses.removeAll()
        for index in settings.keys {
            settings[index] = .auto(index)
        }
        helper.stopHeartbeat()
        let result = await helper.resetAllToAuto()
        refreshReadings()
        return result
    }

    /// Records hardware reads for logging without issuing a command.
    func noteReadback(fanIndex: Int, actual: Double, target: Double) {
        log.verified("fan \(fanIndex)", "read-back actual \(Int(actual)) RPM (target \(Int(target)))")
    }
}

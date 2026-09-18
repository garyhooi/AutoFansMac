//
//  UnlockSequencer.swift
//  SMCKit
//
//  The per-generation fan-control state machine from PROMPT.md §4.6.
//
//  It is pure logic over `SMCAccess` + an injected `SMCClock`, which is what makes
//  the awkward hardware paths testable without hardware: the M1 direct path, the
//  M3/M4 `Ftst` unlock (firmware 0x82 then a daemon yield), the M5 lowercase `F%dmd`
//  path with no `Ftst`, the Intel `FS! ` bitmask, and honest failure when the
//  firmware simply refuses.
//
//  Timing constants mirror the shipped Stats parameters (SMC/smc.swift): mode writes
//  10 × 50 ms, `Ftst` writes up to 100 × 50 ms, then a bound on how long we wait for
//  thermalmonitord to yield.
//

import Foundation

// MARK: - Failure model

/// Why a fan command could not be carried out. Surfaced verbatim in the UI so the app
/// never pretends a write succeeded (PROMPT.md §6.7.8).
public enum FanControlFailure: Error, Equatable, LocalizedError {
    case fanNotFound(Int)
    case modeKeyNotFound(String)
    /// The firmware refuses manual mode and there is no `Ftst` to unlock it.
    case firmwareRefusedManualMode(smcCode: UInt8?)
    case ftstWriteFailed(smcCode: UInt8?)
    case unlockTimedOut
    case targetWriteFailed(smcCode: UInt8?)
    case modeWriteFailed(smcCode: UInt8?)
    /// `kIOReturnNotPrivileged` — the caller is not root, so the helper must do it.
    case permissionDenied
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .fanNotFound(let index):
            return "Fan \(index) does not exist on this Mac."
        case .modeKeyNotFound(let key):
            return "SMC key \(key) does not exist on this Mac."
        case .firmwareRefusedManualMode(let code):
            let detail = code.map { String(format: " (SMC 0x%02X)", $0) } ?? ""
            return "Custom mode is unavailable on this Mac (firmware refused)\(detail)."
        case .ftstWriteFailed(let code):
            let detail = code.map { String(format: " (SMC 0x%02X)", $0) } ?? ""
            return "The fan-control unlock key Ftst could not be set\(detail)."
        case .unlockTimedOut:
            return "Timed out waiting for the system thermal daemon to release fan control."
        case .targetWriteFailed(let code):
            let detail = code.map { String(format: " (SMC 0x%02X)", $0) } ?? ""
            return "The fan target RPM was rejected\(detail)."
        case .modeWriteFailed(let code):
            let detail = code.map { String(format: " (SMC 0x%02X)", $0) } ?? ""
            return "The fan mode change was rejected\(detail)."
        case .permissionDenied:
            return "Writing fan keys requires root — the privileged helper is not available."
        case .notConnected:
            return "Not connected to AppleSMC."
        }
    }

    /// A short reason suitable for the per-fan status badge.
    public var shortReason: String {
        switch self {
        case .permissionDenied: return "Helper required"
        case .firmwareRefusedManualMode: return "Custom mode unavailable (firmware refused)"
        case .unlockTimedOut: return "Unlock timed out"
        case .ftstWriteFailed: return "Unlock key rejected"
        case .modeKeyNotFound: return "Mode key missing"
        case .fanNotFound: return "Fan missing"
        case .targetWriteFailed: return "Target rejected"
        case .modeWriteFailed: return "Mode rejected"
        case .notConnected: return "SMC unavailable"
        }
    }
}

// MARK: - Parameters

/// Retry/timeout budget. Defaults are the documented, hardware-verified values.
public struct UnlockParameters: Sendable, Equatable {
    public var modeWriteAttempts: Int = 10
    public var modeWriteDelayMilliseconds: Int = 50
    public var ftstWriteAttempts: Int = 100
    public var ftstWriteDelayMilliseconds: Int = 50
    /// Poll cadence while waiting for `thermalmonitord` to yield.
    public var yieldPollIntervalMilliseconds: Int = 100
    /// Upper bound on the yield wait (≈30 s, per the reference implementation).
    public var yieldTimeoutMilliseconds: Int = 30_000
    public var targetWriteAttempts: Int = 10
    public var targetWriteDelayMilliseconds: Int = 50
    /// Upper bound on how long we watch `F%dAc`. A fan that is moving exits early; only a
    /// fan that never budges pays the whole window.
    public var verificationWindowMilliseconds: Int = 3_000
    public var verificationPollMilliseconds: Int = 250
    /// |commanded − actual| tolerance = max(this, ratio × commanded).
    public var verificationToleranceRPM: Double = 50
    public var verificationToleranceRatio: Double = 0.05
    /// Movement from the baseline that proves the fan is responding, as
    /// max(absolute, ratio × commanded). A spooling fan clears this in one poll.
    public var verificationStallRPM: Double = 50
    public var verificationStallRatio: Double = 0.02

    /// Window used when the fan was *stopped* and has to start moving.
    ///
    /// Static friction is real: a fan sitting at 0 RPM takes noticeably longer to break free
    /// than a spinning one takes to change speed. With the normal 3 s window a healthy
    /// spin-up was reported as "The fan did not move after a N RPM command" — observed on a
    /// MacBook Pro M5 Pro, where the fans idle at 0 RPM and spin up to their 2317 RPM minimum
    /// only after several seconds.
    public var verificationSpinUpWindowMilliseconds: Int = 6_000
    /// At or below this RPM the fan counts as stopped.
    public var verificationStoppedRPM: Double = 100

    public init() {}
}

/// How a fan reacted to a commanded target.
///
/// The three cases are genuinely different and must not be collapsed: a fan that is still
/// spinning up is *responding*, and reporting it as broken is a lie the user can see
/// through (they watch the RPM climb while the app says "did not respond").
public enum FanResponse: String, Sendable, Codable, Equatable {
    /// Within tolerance of the commanded RPM.
    case atTarget
    /// Accepted and the fan is moving — normal while it spins up or coasts down. A fan
    /// going 0 → 7800 RPM takes several seconds, far longer than any sane poll window.
    case converging
    /// Accepted, and the fan never moved at all. Not a write failure: the hardware
    /// ignored the command (PROMPT.md pitfall #13).
    case stalled
}

/// What actually happened to a commanded target.
public struct FanTargetOutcome: Sendable, Equatable {
    public var targetRPM: Double
    /// The firmware accepted the write.
    public var applied: Bool
    public var response: FanResponse
    /// The raw SMC status byte when the firmware answered something (0x87 esp.).
    public var smcCode: UInt8?
    public var actualRPM: Double

    /// `F%dAc` reached the commanded value within tolerance.
    public var verified: Bool { response == .atTarget }
    /// The write succeeded but the fan never moved.
    public var unresponsive: Bool { response == .stalled }
    /// Still on its way to the commanded value.
    public var converging: Bool { response == .converging }

    public init(
        targetRPM: Double,
        applied: Bool,
        response: FanResponse,
        smcCode: UInt8?,
        actualRPM: Double
    ) {
        self.targetRPM = targetRPM
        self.applied = applied
        self.response = response
        self.smcCode = smcCode
        self.actualRPM = actualRPM
    }
}

// MARK: - Events

/// One line in the diagnostics ring buffer.
public struct FanControlEvent: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        case info, applied, verified, warning, failure
    }

    public let timestamp: Date
    public let fanIndex: Int?
    public let key: String?
    public let level: Level
    public let message: String

    public init(timestamp: Date, fanIndex: Int?, key: String?, level: Level, message: String) {
        self.timestamp = timestamp
        self.fanIndex = fanIndex
        self.key = key
        self.level = level
        self.message = message
    }

    public var formatted: String {
        let fan = fanIndex.map { "fan \($0)" } ?? "-"
        let key = key.map { " [\($0)]" } ?? ""
        return "\(Self.formatter.string(from: timestamp)) \(level.rawValue.uppercased()) \(fan)\(key): \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Sequencer

/// Drives mode/target/release commands against a fan, handling every generation.
///
/// One instance belongs to the process that holds the SMC write privilege (the helper),
/// but it is equally usable in-process on machines that need no privilege (reads) and
/// in the `afmctl` debug tool.
public final class UnlockSequencer {

    public let snapshot: FanHardwareSnapshot
    public var parameters: UnlockParameters
    public var onEvent: ((FanControlEvent) -> Void)?

    private let access: SMCAccess
    private let clock: SMCClock
    /// True while we are the ones holding `Ftst = 1`.
    public private(set) var isFtstHeld = false
    /// Fans we have successfully placed in manual mode.
    public private(set) var manualFans: Set<Int> = []
    /// Bounded diagnostic ring (last 500 events), mirroring the app's buffer.
    public private(set) var events: [FanControlEvent] = []
    private let eventLimit = 500

    public init(
        access: SMCAccess,
        snapshot: FanHardwareSnapshot,
        clock: SMCClock = SystemSMCClock(),
        parameters: UnlockParameters = UnlockParameters()
    ) {
        self.access = access
        self.snapshot = snapshot
        self.clock = clock
        self.parameters = parameters
    }

    // MARK: Fan lookup

    public func fan(_ index: Int) -> FanDescriptor? {
        snapshot.fans.first { $0.index == index }
    }

    // MARK: Ensure manual mode

    /// Places one fan in manual mode, performing the generation-specific unlock.
    ///
    /// Algorithm (PROMPT.md §4.6):
    /// 1. already manual → done
    /// 2. direct mode write, retried (M1/M5/Intel)
    /// 3. firmware refused → probe `Ftst`; absent means honest failure
    /// 4. set `Ftst = 1`
    /// 5. poll until the thermal daemon yields, re-writing the mode key
    @discardableResult
    public func ensureManualMode(_ fan: FanDescriptor) -> Result<Void, FanControlFailure> {
        // 1. Already ours?
        if let mode = access.readInt(fan.modeKey), mode == 1 {
            manualFans.insert(fan.index)
            return .success(())
        }

        // 2. Direct write.
        let direct = writeWithRetry(
            fan.modeKey,
            bytes: [1],
            attempts: parameters.modeWriteAttempts,
            delayMilliseconds: parameters.modeWriteDelayMilliseconds
        )
        if direct.isSuccess {
            log(.info, fan.index, fan.modeKey, "manual mode accepted directly (no unlock needed)")
            if snapshot.hasForceMask { setForceMask(fan.index, forced: true) }
            manualFans.insert(fan.index)
            return .success(())
        }

        if direct.isPermissionDenied {
            return .failure(.permissionDenied)
        }
        let directCode = direct.smcCode
        if directCode == .notFound {
            return .failure(.modeKeyNotFound(fan.modeKey))
        }

        // 3. The firmware refused. Is there an unlock key at all?
        guard snapshot.hasFtst else {
            // M5-style machines never need it, so reaching here means the firmware
            // genuinely refused and there is nothing left to try. Fail honestly.
            log(.failure, fan.index, fan.modeKey,
                "firmware refused manual mode and this Mac has no Ftst unlock key")
            return .failure(.firmwareRefusedManualMode(smcCode: directCode?.rawValue))
        }

        // 4. Raise Ftst.
        if !isFtstHeld {
            if let current = access.readInt("Ftst"), current == 1 {
                isFtstHeld = true
                log(.info, nil, "Ftst", "unlock key already set")
            } else {
                let ftst = writeWithRetry(
                    "Ftst",
                    bytes: [1],
                    attempts: parameters.ftstWriteAttempts,
                    delayMilliseconds: parameters.ftstWriteDelayMilliseconds
                )
                if ftst.isPermissionDenied { return .failure(.permissionDenied) }
                guard ftst.isSuccess else {
                    log(.failure, nil, "Ftst",
                        "could not set the unlock key (\(ftst.smcCode?.localizedDescription ?? "IOKit error"))")
                    return .failure(.ftstWriteFailed(smcCode: ftst.smcCode?.rawValue))
                }
                isFtstHeld = true
                log(.info, nil, "Ftst", "unlock key set; waiting for thermalmonitord to yield")
            }
        }

        // 5. Wait for the daemon to yield, retrying the mode write as we poll.
        let deadline = clock.now + Double(parameters.yieldTimeoutMilliseconds) / 1000.0
        var yielded = false
        while clock.now < deadline {
            clock.sleep(milliseconds: parameters.yieldPollIntervalMilliseconds)

            if !yielded, let mode = access.readInt(fan.modeKey), mode == 0 {
                yielded = true
                log(.info, fan.index, fan.modeKey, "thermal daemon released control (mode 3 → 0)")
            }

            let attempt = access.writeRaw(fan.modeKey, bytes: [1])
            if attempt.isSuccess {
                log(.applied, fan.index, fan.modeKey, "manual mode acquired after unlock")
                if snapshot.hasForceMask { setForceMask(fan.index, forced: true) }
                manualFans.insert(fan.index)
                return .success(())
            }
            if attempt.isPermissionDenied { return .failure(.permissionDenied) }
        }

        log(.failure, fan.index, fan.modeKey, "unlock timed out after \(parameters.yieldTimeoutMilliseconds) ms")
        return .failure(.unlockTimedOut)
    }

    // MARK: Set target

    /// Commands an absolute RPM, verifying that the fan actually responds.
    @discardableResult
    public func setTarget(fan: FanDescriptor, rpm: Double) -> Result<FanTargetOutcome, FanControlFailure> {
        if let manual = ensureManualMode(fan).failureOrNil { return .failure(manual) }

        // Baseline before the write: movement is measured against this.
        let before = access.readDouble(fan.actualKey) ?? fan.currentRPM

        let info = access.keyInfo(fan.targetKey)
        let dataType = info?.dataType ?? fan.valueType
        let byteCount = Int(info?.dataSize ?? UInt32(fan.valueSize))

        let encoded: [UInt8]
        do {
            encoded = try SMCCodecs.encode(double: rpm, dataType: dataType, byteCount: byteCount)
        } catch {
            return .failure(.targetWriteFailed(smcCode: nil))
        }

        let write = writeWithRetry(
            fan.targetKey,
            bytes: encoded,
            attempts: parameters.targetWriteAttempts,
            delayMilliseconds: parameters.targetWriteDelayMilliseconds
        )

        var applied = write.isSuccess

        if write.isPermissionDenied { return .failure(.permissionDenied) }

        // 0x87 size mismatch on F%dTg is often applied anyway — read it back before
        // declaring failure (PROMPT.md pitfall #3).
        if !applied, write.smcCode == .sizeMismatch {
            if let readBack = access.readDouble(fan.targetKey),
               abs(readBack - rpm) <= max(parameters.verificationToleranceRPM, rpm * parameters.verificationToleranceRatio) {
                applied = true
                log(.warning, fan.index, fan.targetKey,
                    "firmware answered 0x87 but the value was applied (\(Int(readBack)) RPM)")
            }
        }

        guard applied else {
            log(.failure, fan.index, fan.targetKey, "target \(Int(rpm)) RPM rejected (\(write.smcCode?.localizedDescription ?? "unknown error"))")
            return .failure(.targetWriteFailed(smcCode: write.smcCode?.rawValue))
        }

        let observation = observe(fan: fan, target: rpm, baseline: before)

        let outcome = FanTargetOutcome(
            targetRPM: rpm,
            applied: true,
            response: observation.response,
            smcCode: nil,
            actualRPM: observation.actual
        )

        switch observation.response {
        case .atTarget:
            log(.verified, fan.index, fan.actualKey,
                "target \(Int(rpm)) RPM verified (actual \(Int(observation.actual)))")
        case .converging:
            // Not a failure and not "active" either: the fan is on its way. The watchdog
            // and the next poll settle the badge once it arrives.
            log(.info, fan.index, fan.actualKey,
                "target \(Int(rpm)) RPM accepted; fan spinning up (at \(Int(observation.actual)) RPM)")
        case .stalled:
            log(.warning, fan.index, fan.actualKey,
                "fan did not move from \(Int(observation.baseline)) RPM after a \(Int(rpm)) RPM command — "
                + "marked unresponsive (the write itself succeeded)")
        }
        return .success(outcome)
    }

    /// Watches `F%dAc` for up to the verification window and classifies the response.
    ///
    /// The key insight: a large fan takes seconds to travel between 0 and 7800 RPM, so
    /// "has not arrived yet" is the normal case, not a fault. Responsiveness is proven by
    /// *movement*, and only a fan that never budges is unresponsive.
    private func observe(
        fan: FanDescriptor,
        target: Double,
        baseline: Double
    ) -> (response: FanResponse, actual: Double, baseline: Double) {
        let tolerance = max(parameters.verificationToleranceRPM, target * parameters.verificationToleranceRatio)
        let stallThreshold = max(parameters.verificationStallRPM, target * parameters.verificationStallRatio)

        // A fan that has to start moving gets longer than one that is already turning.
        let startingFromRest = baseline <= parameters.verificationStoppedRPM
            && target > parameters.verificationStoppedRPM
        let window = startingFromRest
            ? parameters.verificationSpinUpWindowMilliseconds
            : parameters.verificationWindowMilliseconds
        let deadline = clock.now + Double(window) / 1000.0

        var actual = access.readDouble(fan.actualKey) ?? baseline
        if abs(actual - target) <= tolerance { return (.atTarget, actual, baseline) }

        var maxTravel = abs(actual - baseline)
        while clock.now < deadline {
            clock.sleep(milliseconds: parameters.verificationPollMilliseconds)
            actual = access.readDouble(fan.actualKey) ?? actual

            if abs(actual - target) <= tolerance { return (.atTarget, actual, baseline) }

            maxTravel = max(maxTravel, abs(actual - baseline))
            if maxTravel >= stallThreshold { return (.converging, actual, baseline) }
        }

        return (maxTravel >= stallThreshold ? .converging : .stalled, actual, baseline)
    }

    // MARK: Release

    /// Returns a fan to macOS control (PROMPT.md §4.6 `releaseAuto`).
    ///
    /// `isLastManualFan` triggers clearing `Ftst`, which is what hands thermals back
    /// to the system daemon. `Ftst` must never be left set when every fan is auto.
    @discardableResult
    public func releaseAuto(fan: FanDescriptor, isLastManualFan: Bool) -> Result<Void, FanControlFailure> {
        let mode = writeWithRetry(
            fan.modeKey,
            bytes: [0],
            attempts: parameters.modeWriteAttempts,
            delayMilliseconds: parameters.modeWriteDelayMilliseconds
        )
        if mode.isPermissionDenied { return .failure(.permissionDenied) }

        // Clear the target so the firmware does not resume a stale RPM later.
        if access.exists(fan.targetKey) {
            _ = access.writeDouble(fan.targetKey, 0)
        }

        if snapshot.hasForceMask { setForceMask(fan.index, forced: false) }

        manualFans.remove(fan.index)

        if isLastManualFan {
            clearFtstIfHeld()
        }

        guard mode.isSuccess else {
            log(.failure, fan.index, fan.modeKey,
                "could not return fan to automatic (\(mode.smcCode?.localizedDescription ?? "IOKit error"))")
            return .failure(.modeWriteFailed(smcCode: mode.smcCode?.rawValue))
        }
        log(.applied, fan.index, fan.modeKey, "returned to macOS control")
        return .success(())
    }

    /// Releases every fan, clearing `Ftst` after the last *manual* fan goes auto.
    @discardableResult
    public func releaseAll() -> [Int: Result<Void, FanControlFailure>] {
        var results: [Int: Result<Void, FanControlFailure>] = [:]
        let lastManualFan = snapshot.fans.map(\.index).filter { manualFans.contains($0) }.last
        for fan in snapshot.fans {
            results[fan.index] = releaseAuto(fan: fan, isLastManualFan: fan.index == lastManualFan)
        }
        // Belt and braces: never walk away with Ftst held.
        clearFtstIfHeld()
        return results
    }

    /// Writes `Ftst = 0` when we are holding it. Safe to call repeatedly.
    @discardableResult
    public func clearFtstIfHeld() -> Bool {
        guard isFtstHeld else { return true }
        guard snapshot.hasFtst else {
            isFtstHeld = false
            return true
        }
        let result = writeWithRetry("Ftst", bytes: [0], attempts: 10, delayMilliseconds: 50)
        if result.isSuccess {
            isFtstHeld = false
            log(.applied, nil, "Ftst", "unlock key cleared")
            return true
        }
        log(.failure, nil, "Ftst", "could not clear the unlock key (\(result))")
        return false
    }

    /// Re-asserts manual mode and the last target for every manual fan. Used by the
    /// helper watchdog after the daemon reclaims control, and after wake.
    @discardableResult
    public func reassert(desired: [Int: Double]) -> [Int: Result<FanTargetOutcome, FanControlFailure>] {
        var results: [Int: Result<FanTargetOutcome, FanControlFailure>] = [:]
        for (index, rpm) in desired {
            guard let fan = fan(index) else {
                results[index] = .failure(.fanNotFound(index))
                continue
            }
            if access.readInt(fan.modeKey) != 1 {
                log(.info, index, fan.modeKey, "re-asserting manual mode (daemon reclaimed control)")
            }
            results[index] = setTarget(fan: fan, rpm: rpm)
            // A fan that is only spinning up is not a failure; say so once, then let it run.
            if case .success(let outcome) = results[index], outcome.converging {
                log(.info, index, fan.actualKey, "fan is still spinning up; leaving it alone")
            }
        }
        return results
    }

    // MARK: - Private

    /// Writes with a bounded retry loop, returning the last result.
    private func writeWithRetry(
        _ key: String,
        bytes: [UInt8],
        attempts: Int,
        delayMilliseconds: Int
    ) -> SMCWriteResult {
        var last: SMCWriteResult = .notConnected
        for attempt in 0..<max(attempts, 1) {
            last = access.writeRaw(key, bytes: bytes)
            if last.isSuccess { return last }
            // A permission failure cannot be retried away, and a missing key will
            // never appear — fail fast instead of burning the retry budget.
            if last.isPermissionDenied || last.smcCode == .notFound { return last }
            if attempt < attempts - 1 { clock.sleep(milliseconds: delayMilliseconds) }
        }
        return last
    }

    /// Intel/T2 only: sets or clears this fan's bit in the `FS! ` force bitmask.
    private func setForceMask(_ index: Int, forced: Bool) {
        guard snapshot.hasForceMask else { return }
        let current = UInt16(clamping: access.readInt("FS! ") ?? 0)
        let updated = FanForceMask.mask(current, setting: index, forced: forced)
        guard updated != current else { return }
        let result = writeWithRetry("FS! ", bytes: [UInt8(updated >> 8), UInt8(updated & 0xFF)],
                                    attempts: 5, delayMilliseconds: 50)
        if result.isSuccess {
            log(.info, index, "FS! ", "force bitmask now 0x\(String(updated, radix: 16))")
        } else {
            log(.warning, index, "FS! ", "could not update the force bitmask (\(result))")
        }
    }

    private func log(_ level: FanControlEvent.Level, _ fanIndex: Int?, _ key: String?, _ message: String) {
        let event = FanControlEvent(timestamp: Date(), fanIndex: fanIndex, key: key, level: level, message: message)
        events.append(event)
        if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
        onEvent?(event)
    }
}

private extension Result {
    /// `.failure(error)` when this is a failure, otherwise nil.
    var failureOrNil: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

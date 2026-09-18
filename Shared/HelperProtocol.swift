//
//  HelperProtocol.swift
//  Shared (compiled into BOTH the app and the privileged helper)
//
//  The XPC contract between AutoFansMac.app and its root launchd daemon
//  (PROMPT.md §5.3). It lives in `Shared/` on purpose: the interface must be
//  byte-identical on both sides, so there is exactly one source of truth.
//
//  Payloads travel as JSON `Data` rather than `@objc` classes so the wire format is
//  inspectable, versionable and identical to the on-disk profile schema.
//

import Foundation
import SMCKit

// MARK: - Identifiers

public enum HelperConstants {
    /// Mach service name. MUST equal the helper bundle id and the `MachServices` key
    /// in the LaunchDaemon plist.
    public static let machServiceName = "com.autofansmac.AutoFansMac.helper"
    public static let helperBundleIdentifier = "com.autofansmac.AutoFansMac.helper"
    public static let helperPlistName = "com.autofansmac.AutoFansMac.helper.plist"
    public static let helperExecutableName = "AutoFansMacHelper"

    /// Bumped on every release; the app compares it over XPC and re-registers the
    /// daemon when it differs (Stats-proven update flow).
    ///
    /// Kept equal to the app's own `MARKETING_VERSION`, because the two ship together:
    /// both are 1.0.0. The comparison is on inequality, not on ordering, so a daemon left
    /// over from an earlier numbering (1.0.1) is still replaced.
    public static let helperVersion = "1.0.0"

    /// The daemon must live here inside the app bundle for `SMAppService.daemon`.
    public static let helperBundleSubpath = "Contents/Library/LaunchDaemons"

    /// Team identifier used for client code-signature validation.
    /// Replace together with the signing team when you re-badge the app.
    public static let teamIdentifier = "93WWDR82K2"

    /// The app target's `PRODUCT_BUNDLE_IDENTIFIER`, for the LaunchDaemon plist and the docs.
    ///
    /// NOT used to authorise clients — see `HelperClientRequirement` for why.
    public static let defaultAppBundleIdentifier = "dev.g-studio.AutoFansMac"

    /// Optional daemon environment variable pinning the *exact* client bundle identifier.
    ///
    /// When set, the daemon additionally requires this identifier; when absent it authorises by
    /// team alone. `Scripts/dev-install-helper.sh` sets it from the built app's Info.plist, so
    /// the development install stays as strict as it can be without hardcoding a value that a
    /// project setting can silently change.
    public static let expectedClientIdentifierKey = "AUTOFANSMAC_EXPECTED_CLIENT"

    /// Seconds without a heartbeat before the daemon returns fans to macOS control.
    public static let heartbeatTimeout: TimeInterval = 60
    /// The app pings this often while any fan is manual.
    public static let heartbeatInterval: TimeInterval = 15
    /// Watchdog re-assert cadence while any fan is manual.
    public static let watchdogInterval: TimeInterval = 5
}

// MARK: - Client requirement

/// Builds the code-signature requirement the daemon checks a connecting client against.
///
/// Anchoring on the **team identifier** (plus Apple's own anchor) is the part that matters: it
/// means only an app this developer signed can command the fans as root. The bundle identifier is
/// optional on purpose.
///
/// This used to hardcode the app's bundle id, and that is exactly how fan control broke: the
/// project's `PRODUCT_BUNDLE_IDENTIFIER` was `dev.g-studio.AutoFansMac`, the constant said
/// `com.autofansmac.AutoFansMac`, and the daemon then refused **every** connection from its own
/// app — silently, because "connection refused" and "no daemon" look identical to the client.
/// A security check must not depend on a value that can drift out of sync with the thing it is
/// checking.
public enum HelperClientRequirement {

    /// The requirement string, given the signing team and an optional exact identifier.
    public static func string(teamIdentifier: String, expectedIdentifier: String? = nil) -> String {
        var clauses = [
            "anchor apple generic",
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
        ]
        if let expectedIdentifier, !expectedIdentifier.isEmpty {
            clauses.insert("identifier \"\(expectedIdentifier)\"", at: 1)
        }
        return clauses.joined(separator: " and ")
    }

    /// The identifier to pin, read from the daemon's own environment when the installer set it.
    public static func configuredIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment[HelperConstants.expectedClientIdentifierKey],
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

// MARK: - DTOs

/// One fan's desired state, as sent by the app in an `applyFanStates` batch.
public struct FanCommandPayload: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case auto
        case manual
    }

    public var index: Int
    public var mode: Mode
    /// Absolute RPM when `mode == .manual`.
    public var targetRPM: Double?

    public init(index: Int, mode: Mode, targetRPM: Double? = nil) {
        self.index = index
        self.mode = mode
        self.targetRPM = targetRPM
    }

    public static func auto(_ index: Int) -> FanCommandPayload {
        FanCommandPayload(index: index, mode: .auto, targetRPM: nil)
    }

    public static func manual(_ index: Int, rpm: Double) -> FanCommandPayload {
        FanCommandPayload(index: index, mode: .manual, targetRPM: rpm)
    }
}

/// Per-fan result of an `applyFanStates` call — what the UI shows as the badge.
public struct FanCommandStatus: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case idle
        case applying
        case active
        case failed
        /// The write succeeded but `F%dAc` never followed (pitfall #13).
        case unresponsive
    }

    public var index: Int
    public var state: State
    public var targetRPM: Double?
    public var actualRPM: Double?
    public var hardwareMode: FanHardwareMode
    public var message: String?

    public var id: Int { index }

    public init(
        index: Int,
        state: State,
        targetRPM: Double? = nil,
        actualRPM: Double? = nil,
        hardwareMode: FanHardwareMode = .unknown,
        message: String? = nil
    ) {
        self.index = index
        self.state = state
        self.targetRPM = targetRPM
        self.actualRPM = actualRPM
        self.hardwareMode = hardwareMode
        self.message = message
    }
}

/// What the daemon reports about itself and the hardware it can see.
public struct HelperCapabilities: Codable, Sendable, Equatable {
    public var version: String
    public var isRoot: Bool
    public var platform: PlatformInfo
    public var fanCount: Int
    public var hasFtst: Bool
    public var hasForceMask: Bool
    public var modeKeyIsLowercase: Bool
    public var unlockStyle: UnlockStyle
    /// Fans the daemon can actually command (some may be missing `F%dTg`).
    public var controllableFans: [Int]

    public init(
        version: String,
        isRoot: Bool,
        platform: PlatformInfo,
        fanCount: Int,
        hasFtst: Bool,
        hasForceMask: Bool,
        modeKeyIsLowercase: Bool,
        unlockStyle: UnlockStyle,
        controllableFans: [Int]
    ) {
        self.version = version
        self.isRoot = isRoot
        self.platform = platform
        self.fanCount = fanCount
        self.hasFtst = hasFtst
        self.hasForceMask = hasForceMask
        self.modeKeyIsLowercase = modeKeyIsLowercase
        self.unlockStyle = unlockStyle
        self.controllableFans = controllableFans
    }
}

/// Full daemon status, polled by the Settings pane and used by diagnostics.
public struct HelperStatus: Codable, Sendable, Equatable {
    public var version: String
    public var isRoot: Bool
    public var startedAt: Date
    public var lastHeartbeat: Date?
    public var desiredState: [FanCommandPayload]
    public var fanStatus: [FanCommandStatus]
    public var ftstHeld: Bool
    public var watchdogRuns: Int
    public var wakeRecoveries: Int
    public var resetReason: String?

    public init(
        version: String,
        isRoot: Bool,
        startedAt: Date,
        lastHeartbeat: Date?,
        desiredState: [FanCommandPayload],
        fanStatus: [FanCommandStatus],
        ftstHeld: Bool,
        watchdogRuns: Int,
        wakeRecoveries: Int,
        resetReason: String?
    ) {
        self.version = version
        self.isRoot = isRoot
        self.startedAt = startedAt
        self.lastHeartbeat = lastHeartbeat
        self.desiredState = desiredState
        self.fanStatus = fanStatus
        self.ftstHeld = ftstHeld
        self.watchdogRuns = watchdogRuns
        self.wakeRecoveries = wakeRecoveries
        self.resetReason = resetReason
    }
}

// MARK: - XPC protocol

/// The daemon's public interface. Every method is asynchronous with a reply block
/// because a fan command can block for seconds (the M3/M4 unlock waits for the
/// thermal daemon to yield).
@objc(AutoFansMacHelperProtocol)
public protocol HelperProtocol {

    /// The helper's own version string.
    func version(reply: @escaping (String) -> Void)

    /// JSON-encoded `HelperCapabilities` — what this machine can do.
    func capabilities(reply: @escaping (Data) -> Void)

    /// Applies a complete desired fan vector atomically.
    ///
    /// - Parameters:
    ///   - statesJSON: JSON array of `FanCommandPayload`.
    ///   - reply: success, an error message when not successful, and JSON-encoded
    ///     `[FanCommandStatus]` describing each fan.
    func applyFanStates(_ statesJSON: Data, reply: @escaping (Bool, String?, Data?) -> Void)

    /// Returns every fan to macOS control and clears `Ftst`. Never fails silently.
    func resetAllToAuto(reply: @escaping (Bool, String?) -> Void)

    /// Dead-man ping. A `false` reply means the daemon is about to reset fans.
    func heartbeat(reply: @escaping (Bool) -> Void)

    /// Full JSON-encoded `HelperStatus`.
    func status(reply: @escaping (Data) -> Void)

    /// JSON-encoded `[FanControlEvent]` — the daemon's recent fan-control history.
    func recentEvents(reply: @escaping (Data) -> Void)

    /// Clears `Ftst` and stops managing fans, then exits. The app unregisters the
    /// daemon afterwards.
    func uninstall(reply: @escaping (Bool, String?) -> Void)
}

// MARK: - JSON helpers

public enum HelperCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

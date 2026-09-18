//
//  DiagnosticsLog.swift
//  AutoFansMac
//
//  Bounded ring buffer of fan-control events plus the "Export Diagnostics" payload
//  (PROMPT.md §6.6, N9, §6.7.7).
//
//  Every SMC write and its result is recorded here. The buffer is bounded so a
//  long-running session can never grow memory without limit.
//

import Foundation
import SMCKit

/// One entry in the diagnostics ring.
struct DiagnosticEntry: Identifiable, Equatable {
    enum Level: String {
        case info, applied, warning, failure, verified
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let category: String
    let message: String

    var formatted: String {
        "\(Self.formatter.string(from: timestamp)) [\(level.rawValue.uppercased())] \(category): \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

/// Thread-safe, bounded event log.
final class DiagnosticsLog: ObservableObject {

    /// Last 500 events (PROMPT.md §6.7.7).
    static let capacity = 500

    @Published private(set) var entries: [DiagnosticEntry] = []

    private let queue = DispatchQueue(label: "com.autofansmac.diagnostics")
    private var storage: [DiagnosticEntry] = []

    func record(_ level: DiagnosticEntry.Level, _ category: String, _ message: String) {
        let entry = DiagnosticEntry(timestamp: Date(), level: level, category: category, message: message)
        #if DEBUG
        NSLog("[AutoFansMac] %@", entry.formatted)
        #endif
        queue.async {
            self.storage.append(entry)
            if self.storage.count > Self.capacity {
                self.storage.removeFirst(self.storage.count - Self.capacity)
            }
            let snapshot = self.storage
            DispatchQueue.main.async { self.entries = snapshot }
        }
    }

    func info(_ category: String, _ message: String) { record(.info, category, message) }
    func applied(_ category: String, _ message: String) { record(.applied, category, message) }
    func warning(_ category: String, _ message: String) { record(.warning, category, message) }
    func failure(_ category: String, _ message: String) { record(.failure, category, message) }
    func verified(_ category: String, _ message: String) { record(.verified, category, message) }

    /// Ingests events emitted by the SMCKit sequencer.
    func ingest(_ event: FanControlEvent) {
        let level: DiagnosticEntry.Level
        switch event.level {
        case .info: level = .info
        case .applied: level = .applied
        case .verified: level = .verified
        case .warning: level = .warning
        case .failure: level = .failure
        }
        record(level, event.fanIndex.map { "fan \($0)" } ?? (event.key ?? "smc"), event.message)
    }

    func snapshot() -> [DiagnosticEntry] {
        queue.sync { storage }
    }

    func clear() {
        queue.async {
            self.storage.removeAll()
            DispatchQueue.main.async { self.entries = [] }
        }
    }
}

// MARK: - Export

enum DiagnosticsExporter {

    /// Builds the plain-text diagnostics bundle offered by "Export Diagnostics…".
    ///
    /// Deliberately contains no network-related information: v1 makes no network calls
    /// at all (PROMPT.md §7 Phase 10 privacy statement).
    static func makeReport(
        platform: PlatformInfo,
        fanSnapshot: FanHardwareSnapshot,
        scan: SensorScanResult?,
        entries: [DiagnosticEntry],
        profiles: ProfileDocument?,
        activeProfileName: String?,
        helperStatus: HelperStatus?,
        helperCapabilities: HelperCapabilities?,
        smcStatistics: SMCConnection.Statistics,
        settings: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("AutoFansMac diagnostics")
        lines.append("generated:        \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("app version:      \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
        lines.append("")
        lines.append("=== host ===")
        lines.append(platform.diagnosticsDescription)
        lines.append("")
        lines.append("=== smc ===")
        lines.append("connected:        \(smcStatistics.callCount >= 0)")
        lines.append("calls:            \(smcStatistics.callCount)")
        lines.append("errors:           \(smcStatistics.errorCount)")
        lines.append("reconnects:       \(smcStatistics.reconnectCount)")
        lines.append("lastError:        \(smcStatistics.lastError ?? "none")")
        lines.append("fanCount:         \(fanSnapshot.fanCount)")
        lines.append("modeKeyLowercase: \(fanSnapshot.modeKeyIsLowercase)")
        lines.append("hasFtst:          \(fanSnapshot.hasFtst)")
        lines.append("hasForceMask:     \(fanSnapshot.hasForceMask)")
        lines.append("unlockStyle:      \(fanSnapshot.unlockStyle.rawValue)")
        lines.append("")
        lines.append("=== fans ===")
        for fan in fanSnapshot.fans {
            lines.append("fan \(fan.index) \(fan.displayName): min=\(Int(fan.minRPM)) cur=\(Int(fan.currentRPM)) "
                         + "max=\(Int(fan.maxRPM)) mode=\(fan.hardwareMode.rawValue) "
                         + "type=\(fan.valueType.trimmingCharacters(in: .whitespaces)) keys=\(fan.actualKey)/\(fan.targetKey)/\(fan.modeKey)")
            for warning in fan.warnings { lines.append("  ! \(warning)") }
        }
        lines.append("")
        lines.append("=== helper ===")
        if let helperStatus {
            lines.append("version:          \(helperStatus.version)")
            lines.append("isRoot:           \(helperStatus.isRoot)")
            lines.append("startedAt:        \(ISO8601DateFormatter().string(from: helperStatus.startedAt))")
            lines.append("lastHeartbeat:    \(helperStatus.lastHeartbeat.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
            lines.append("ftstHeld:         \(helperStatus.ftstHeld)")
            lines.append("watchdogRuns:     \(helperStatus.watchdogRuns)")
            lines.append("wakeRecoveries:   \(helperStatus.wakeRecoveries)")
            lines.append("resetReason:      \(helperStatus.resetReason ?? "none")")
            for status in helperStatus.fanStatus {
                lines.append("fan \(status.index): \(status.state.rawValue) target=\(status.targetRPM.map { String(Int($0)) } ?? "-") "
                             + "actual=\(status.actualRPM.map { String(Int($0)) } ?? "-") \(status.message ?? "")")
            }
        } else {
            lines.append("not reachable (helper not installed, not approved, or app not responding)")
        }
        if let helperCapabilities {
            lines.append("capabilities: controllableFans=\(helperCapabilities.controllableFans) "
                         + "unlockStyle=\(helperCapabilities.unlockStyle.rawValue)")
        }
        lines.append("")
        lines.append("=== profiles ===")
        lines.append("active:           \(activeProfileName ?? "-")")
        if let profiles {
            for profile in profiles.profiles {
                lines.append("- \(profile.name) [\(profile.id)] builtIn=\(profile.builtIn) \(profile.summary)")
            }
        }
        lines.append("")
        lines.append("=== settings ===")
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("=== sensors ===")
        if let scan {
            lines.append("keys scanned:     \(scan.scannedKeyCount)")
            lines.append("samples:          \(scan.samples.count) (temperatures \(scan.temperatureSamples.count), fans \(scan.fanSamples.count))")
            lines.append("absent keys:      \(scan.absentKeys.count)")
            lines.append("unknown keys:     \(scan.unknownKeys.count)")
            lines.append("scan duration:    \(String(format: "%.1f", scan.duration * 1000)) ms")
            lines.append("")
            lines.append("--- temperature values ---")
            for sample in scan.temperatureSamples {
                lines.append(String(format: "%-7@ %-34@ %8.2f", sample.key as NSString, sample.name as NSString, sample.rawValue))
            }
        } else {
            lines.append("no scan available")
        }
        lines.append("")
        lines.append("=== recent events (newest last, max \(DiagnosticsLog.capacity)) ===")
        for entry in entries { lines.append(entry.formatted) }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var buildVersion: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}

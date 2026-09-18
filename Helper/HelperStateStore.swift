//
//  HelperStateStore.swift
//  AutoFansMacHelper
//
//  Crash-recovery state file (PROMPT.md §5.3).
//
//  If the daemon dies (or is killed) while fans are in manual mode, the *next* daemon
//  start finds this file and returns every fan to macOS control before doing anything
//  else. That is the last line of defence behind the watchdog, the dead-man switch and
//  the SIGTERM handler: the machine must never be left with `Ftst = 1` or a pinned fan
//  and nobody driving it.
//

import Foundation
import SMCKit

/// What the daemon persists so a subsequent run can clean up.
struct HelperPersistedState: Codable, Equatable {
    var manualActive: Bool
    var desiredState: [FanCommandPayload]
    var timestamp: Date
    var helperVersion: String
    /// Set when the daemon believes it is holding `Ftst = 1`.
    var ftstHeld: Bool
}

final class HelperStateStore {

    /// `/Library/Application Support/AutoFansMac/helper-state.json` — root-owned,
    /// outside the app bundle so it survives app updates and helper reinstalls.
    static let directoryURL = URL(fileURLWithPath: "/Library/Application Support/AutoFansMac", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("helper-state.json")

    private let fileManager = FileManager.default

    init() {}

    /// True when a stale state file exists — i.e. the previous daemon run did not exit
    /// cleanly.
    var hasStaleState: Bool {
        fileManager.fileExists(atPath: Self.fileURL.path)
    }

    func load() -> HelperPersistedState? {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
        return HelperCoding.decode(HelperPersistedState.self, from: data)
    }

    @discardableResult
    func save(_ state: HelperPersistedState) -> Bool {
        do {
            try fileManager.createDirectory(
                at: Self.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try HelperCoding.encode(state).write(to: Self.fileURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.fileURL.path)
            return true
        } catch {
            NSLog("[AutoFansMacHelper] could not persist state: \(error.localizedDescription)")
            return false
        }
    }

    func clear() {
        try? fileManager.removeItem(at: Self.fileURL)
    }
}

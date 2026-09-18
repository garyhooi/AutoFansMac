//
//  LaunchdJob.swift
//  AutoFansMac
//
//  "Does launchd still have our daemon job?" — the one question `SMAppService` cannot
//  answer, and the one that decides whether the helper is repairable.
//
//  `SMAppService` reports its own registration record, and it is precisely that record
//  which goes stale when the app bundle is replaced: BackgroundTaskManagement keeps a code
//  requirement (LWCR) tied to the executable's ad-hoc signature, the new bundle no longer
//  matches it, and the record ends up describing an app URL that no longer resolves. From
//  then on the record can report "not found" while launchd is still holding the submitted
//  job and retrying the spawn every 10 s. Trusting that status alone made the app conclude
//  there was nothing to repair, and leave the user to press Install again.
//
//  `launchctl print` is the authoritative answer, it needs no privileges, and it is the
//  very command this app tells users to run when the daemon will not start.
//

import Foundation

enum LaunchdJob {

    /// True when launchd has a job with this label in the system domain.
    static func exists(label: String) async -> Bool {
        await withCheckedContinuation { continuation in
            // launchctl is a process, and this is called from the main actor: never make the
            // UI wait on it.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: existsSynchronously(label: label))
            }
        }
    }

    private static func existsSynchronously(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // No launchctl, no answer. "Not there" is the safe reading: it only means the app
            // will not try to repair a registration it cannot see.
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

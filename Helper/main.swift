//
//  main.swift
//  AutoFansMacHelper
//
//  The privileged root launchd daemon.
//
//  Started on demand by launchd (the LaunchDaemon plist has RunAtLoad = false) as soon
//  as the app opens an `NSXPCConnection(machServiceName:options:.privileged)`, and kept
//  alive while any fan is manual. It exits once the last client disconnects and no fan
//  needs it any more.
//
//  Safety contract (PROMPT.md §6.7): whatever happens — SIGTERM, SIGINT, a crash, or the
//  app vanishing — the machine must not be left with `Ftst = 1` or a pinned fan that
//  nobody is driving. Three mechanisms cover it: this signal handler, the crash-recovery
//  state file read at startup, and the dead-man heartbeat in FanControlSession.
//

import Foundation
import SMCKit

let helper = HelperService()

// MARK: - Signals

/// Reset fans and clear Ftst before exiting. Only async-signal-safe work is skipped —
/// we do the SMC writes here deliberately, because the alternative is leaving a Mac
/// with its fans pinned.
func handleTerminationSignal(_ signalNumber: Int32) {
    NSLog("[AutoFansMacHelper] received signal \(signalNumber) — restoring automatic fan control")
    helper.session.shutdown(reason: "signal \(signalNumber)")
    exit(EXIT_SUCCESS)
}

signal(SIGTERM, handleTerminationSignal)
signal(SIGINT, handleTerminationSignal)
signal(SIGHUP, handleTerminationSignal)

// Ignore SIGPIPE: a client disconnecting mid-reply must not kill the daemon.
signal(SIGPIPE, SIG_IGN)

// MARK: - Start

if getuid() != 0 {
    // Reads would still work, but writes cannot: refuse loudly instead of pretending.
    FileHandle.standardError.write(
        Data("AutoFansMacHelper must run as root (launchd does this). Use Tools/afmctl for unprivileged reads.\n".utf8)
    )
    exit(EXIT_FAILURE)
}

NSLog("[AutoFansMacHelper] starting v\(HelperConstants.helperVersion) as uid \(getuid())")

// Crash recovery + hardware probe happen before the listener serves anything.
helper.session.start()

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = helper
listener.resume()

NSLog("[AutoFansMacHelper] listening on mach service \(HelperConstants.machServiceName)")

// The main run loop drives both the XPC listener and the IOKit power-notification
// source registered by the session.
RunLoop.main.run()

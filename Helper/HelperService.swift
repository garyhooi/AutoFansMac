//
//  HelperService.swift
//  AutoFansMacHelper
//
//  XPC listener delegate + `HelperProtocol` implementation, and — critically — the
//  client authentication that stops *any* local process from spinning this machine's
//  fans as root (PROMPT.md §5.3, pitfall #16).
//
//  Authentication uses public API only: the connecting process's pid
//  (`NSXPCConnection.processIdentifier`) is turned into a `SecCode` and checked against
//  a designated requirement (Apple-anchored, our team identifier, our bundle id).
//

import Foundation
import Security
import os
import SMCKit

final class HelperService: NSObject, NSXPCListenerDelegate, HelperProtocol {

    let session = FanControlSession()

    /// Number of live client connections. The daemon exits when the last one drops and
    /// no fan is manual — there is nothing to keep running for.
    private let connectionLock = NSLock()
    private var activeConnections = 0
    private var exitWhenIdle = false

    // MARK: - Listener

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isClientTrusted(newConnection) else {
            let pid = newConnection.processIdentifier
            let identifier = Self.signingIdentifier(of: pid) ?? "unknown"
            let requirement = HelperClientRequirement.string(
                teamIdentifier: HelperConstants.teamIdentifier,
                expectedIdentifier: HelperClientRequirement.configuredIdentifier()
            )
            Self.authLog.error("REFUSED connection from pid \(pid, privacy: .public) identifier \(identifier, privacy: .public) — signature does not satisfy: \(requirement, privacy: .public)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = { [weak self] in
            self?.connectionClosed()
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.connectionClosed()
        }

        connectionLock.lock()
        activeConnections += 1
        connectionLock.unlock()

        newConnection.resume()
        NSLog("[AutoFansMacHelper] accepted connection from pid \(newConnection.processIdentifier)")
        return true
    }

    private func connectionClosed() {
        connectionLock.lock()
        activeConnections = max(0, activeConnections - 1)
        let shouldExit = exitWhenIdle && activeConnections == 0 && session.manualFanIndices.isEmpty
        connectionLock.unlock()

        if shouldExit {
            NSLog("[AutoFansMacHelper] last client disconnected and no fan is manual — exiting")
            exit(EXIT_SUCCESS)
        }
    }

    /// Ask the daemon to quit once the last client disconnects (used by uninstall).
    func exitWhenIdleAfterUninstall() {
        connectionLock.lock()
        exitWhenIdle = true
        let shouldExit = activeConnections == 0
        connectionLock.unlock()
        if shouldExit { exit(EXIT_SUCCESS) }
    }

    // MARK: - Client authentication

    /// The designated requirement the connecting client must satisfy.
    ///
    /// `anchor apple generic` pins the certificate chain to Apple's and the OU is the signing
    /// team, so only an app this developer signed can drive the fans as root. The bundle id is
    /// pinned as well *when the installer configured one* — see `HelperClientRequirement`.
    private var clientRequirement: SecRequirement? {
        let requirementString = HelperClientRequirement.string(
            teamIdentifier: HelperConstants.teamIdentifier,
            expectedIdentifier: HelperClientRequirement.configuredIdentifier()
        )
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
        if status != errSecSuccess {
            Self.authLog.error("could not build the client requirement (OSStatus \(status, privacy: .public))")
            return nil
        }
        return requirement
    }

    /// Security-relevant logging. Uses `os.Logger` with public privacy because `NSLog` redacts
    /// strings to `<private>` in the unified log — a refused connection was invisible, which is
    /// most of why this failure took as long as it did to find.
    private static let authLog = Logger(subsystem: HelperConstants.helperBundleIdentifier, category: "auth")

    /// The connecting process's code-signing identifier, for the refusal log.
    private static func signingIdentifier(of pid: pid_t) -> String? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code
        ) == errSecSuccess, let code else { return nil }

        // Signing information lives on the *static* code, not the dynamic guest object.
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }

    private func isClientTrusted(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG || AUTOFANSMAC_UNSIGNED_BUILD
        // Documented escape hatch, opt-in through the *daemon's* environment, never by
        // default (see Docs/DISTRIBUTING.md):
        //
        //   DEBUG                    ad-hoc signed debug builds, which cannot satisfy
        //                            the Developer ID requirement.
        //   AUTOFANSMAC_UNSIGNED_BUILD  the community build (Scripts/package-unsigned.sh),
        //                            distributed with no Apple account at all. It has no
        //                            signing team to pin, so the requirement below could
        //                            never be met and fan control would be dead on arrival.
        //
        // A Developer ID Release helper does not compile this branch, so an official
        // build still refuses every client that is not signed by the team.
        if ProcessInfo.processInfo.environment["AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS"] == "1" {
            NSLog("[AutoFansMacHelper] WARNING: client validation disabled by AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS")
            return true
        }
        #endif

        let pid = connection.processIdentifier
        guard pid > 0 else { return false }

        guard let requirement = clientRequirement else { return false }

        let attributes: [CFString: Any] = [kSecGuestAttributePid: pid]
        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            NSLog("[AutoFansMacHelper] SecCodeCopyGuestWithAttributes failed for pid \(pid) (OSStatus \(copyStatus))")
            return false
        }

        let validity = SecCodeCheckValidity(code, [], requirement)
        return validity == errSecSuccess
    }

    // MARK: - HelperProtocol

    func version(reply: @escaping (String) -> Void) {
        session.noteClientActivity()
        reply(HelperConstants.helperVersion)
    }

    func capabilities(reply: @escaping (Data) -> Void) {
        session.noteClientActivity()
        reply(HelperCoding.encode(session.capabilities()))
    }

    func applyFanStates(_ statesJSON: Data, reply: @escaping (Bool, String?, Data?) -> Void) {
        // Recorded before the work starts: unlocking a fan can take seconds, and the app is
        // very much alive while it waits.
        session.noteClientActivity()
        guard let payloads = HelperCoding.decode([FanCommandPayload].self, from: statesJSON) else {
            reply(false, "The fan state payload was not valid JSON.", nil)
            return
        }
        let result = session.applyFanStates(payloads)
        reply(result.success, result.error, HelperCoding.encode(result.statuses))
    }

    func resetAllToAuto(reply: @escaping (Bool, String?) -> Void) {
        session.noteClientActivity()
        let result = session.resetAllToAuto(reason: "Requested by the app")
        reply(result.success, result.error)
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        reply(session.heartbeat())
    }

    func status(reply: @escaping (Data) -> Void) {
        session.noteClientActivity()
        reply(HelperCoding.encode(session.status()))
    }

    func recentEvents(reply: @escaping (Data) -> Void) {
        session.noteClientActivity()
        reply(HelperCoding.encode(session.eventLog()))
    }

    func uninstall(reply: @escaping (Bool, String?) -> Void) {
        let result = session.resetAllToAuto(reason: "Helper uninstall requested by the app")
        session.shutdown(reason: "uninstall")
        reply(result.success, result.error)
        // Give the reply a moment to flush before launchd reaps us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.exitWhenIdleAfterUninstall()
        }
    }
}

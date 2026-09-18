//
//  HelperClient.swift
//  AutoFansMac
//
//  The app's side of the privileged-helper relationship (PROMPT.md §5.3, §6.8):
//  SMAppService registration/approval, the NSXPCConnection lifecycle, heartbeats, and
//  a dev-friendly diagnosis of exactly *why* the helper is unusable.
//

import Foundation
import ServiceManagement
import SMCKit

/// Everything that can go wrong talking to the helper, phrased for the UI.
enum HelperError: LocalizedError, Equatable {
    case notInstalled
    case requiresApproval
    case appNotInApplications(String)
    case connectionFailed(String)
    case replyFailed
    case timedOut(seconds: Double)
    case daemonReported(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The privileged helper is not installed, so fans cannot be commanded."
        case .requiresApproval:
            return "The helper needs your approval in System Settings → General → Login Items."
        case .appNotInApplications(let path):
            return "Fan control from \(path) needs a development daemon: "
                + "run  sudo Scripts/dev-install-helper.sh install  in the repository. "
                + "(The bundled daemon only works from /Applications, because its launch path is fixed there.)"
        case .connectionFailed(let detail):
            return "Could not talk to the helper: \(detail)"
        case .replyFailed:
            return "The helper did not answer."
        case .timedOut(let seconds):
            return "The helper did not respond within \(Int(seconds)) s."
        case .daemonReported(let message):
            return message
        }
    }

    /// True when fan control is simply not set up yet, rather than a command having
    /// failed. Monitoring-only is a supported state (PROMPT.md N7) and must not be
    /// reported as a fan-control error.
    var isPreconditionFailure: Bool {
        switch self {
        case .notInstalled, .requiresApproval, .appNotInApplications:
            return true
        case .connectionFailed, .replyFailed, .timedOut, .daemonReported:
            return false
        }
    }
}

/// Registers, monitors and talks to the root helper daemon.
final class HelperClient: NSObject, ObservableObject {

    enum InstallationState: Equatable {
        case unknown
        case notInstalled
        case requiresApproval
        case installed
        case unavailable(String)

        /// Shared reason string so the UI can recognise the "not in /Applications" case.
        static let notInApplicationsReason = "app is not in /Applications"

        /// Shared reason string for "the system has this daemon registered, but launchd will
        /// not start it" — see `HelperClient.probe()` for the mechanism.
        static let registeredButNotRespondingReason = "the helper is registered, but macOS will not start it"

        /// True for the state above, which is the one the app can repair by itself.
        var isRegisteredButNotResponding: Bool {
            if case .unavailable(let reason) = self {
                return reason == Self.registeredButNotRespondingReason
            }
            return false
        }

        var displayName: String {
            switch self {
            case .unknown: return "Checking…"
            case .notInstalled: return "Not installed"
            case .requiresApproval: return "Waiting for approval"
            case .installed: return "Installed"
            case .unavailable(let reason): return "Unavailable — \(reason)"
            }
        }

        var isUsable: Bool { self == .installed }

        /// The error to report when a command is attempted in this state. These are
        /// preconditions, not command failures: see `HelperError.isPreconditionFailure`.
        func preconditionError(bundlePath: String) -> HelperError {
            switch self {
            case .requiresApproval:
                return .requiresApproval
            case .unavailable(let reason) where reason == Self.notInApplicationsReason:
                return .appNotInApplications(bundlePath)
            case .installed, .unknown, .notInstalled, .unavailable:
                return .notInstalled
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var installationState: InstallationState = .unknown
    @Published private(set) var isConnected = false
    @Published private(set) var capabilities: HelperCapabilities?
    @Published private(set) var lastError: String?
    /// Set when a version mismatch was found and a re-register is required.
    @Published private(set) var needsReinstall = false

    // MARK: - Internals

    /// One registration repair per run. A failure is not transient (nothing about the
    /// system changes by retrying), so the 30 s re-probe must not loop on it.
    private var hasAttemptedRegistrationRepair = false

    /// True when `SMAppService` holds an enabled (registered and approved) daemon record.
    ///
    /// This is *not* "the daemon is running": see `probe()`.
    private var isRegisteredWithSMAppService: Bool {
        SMAppService.daemon(plistName: HelperConstants.helperPlistName).status == .enabled
    }

    private var connection: NSXPCConnection?
    /// True once a daemon has answered. Until then, a failed lookup is the expected
    /// answer to "is fan control set up?", not a fault worth logging as one.
    private var everConnected = false
    private let stateQueue = DispatchQueue(label: "com.autofansmac.helperclient")
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectAttempts = 0
    private var log: DiagnosticsLog?

    /// True when this build can plausibly use SMAppService at all.
    var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// True when a LaunchDaemon plist is present in the system location.
    ///
    /// A registered-but-silent daemon is a different problem from an uninstalled one: it
    /// usually means launchd cannot start it (most often a dyld failure because the
    /// binary depends on something that is not part of the system). Saying "not installed"
    /// there sends the user down the wrong path, so it gets its own message.
    var hasRegisteredDaemonPlist: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/\(HelperConstants.helperPlistName)"
        )
    }

    var bundlePath: String { Bundle.main.bundlePath }

    func attach(log: DiagnosticsLog) {
        self.log = log
    }

    // MARK: - Installation

    /// `SMAppService` exposes both a throwing and a completion-handler variant of
    /// `register`/`unregister`; calling them from a non-async helper keeps overload
    /// resolution on the plain throwing form.
    private func registerDaemon() throws {
        try SMAppService.daemon(plistName: HelperConstants.helperPlistName).register()
    }

    private func unregisterDaemon() throws {
        try SMAppService.daemon(plistName: HelperConstants.helperPlistName).unregister()
    }

    /// The SMAppService view of the world, which is only half the story.
    ///
    /// It answers "can the system launch a daemon from THIS app bundle?" — and the honest
    /// answer is no when the app is not in `/Applications`, because the shipped
    /// LaunchDaemon plist pins `ProgramArguments` to the canonical install path.
    ///
    /// It does NOT answer "is a daemon answering on the Mach service?", which is what
    /// actually matters for fan control. A development daemon bootstrapped by
    /// `Scripts/dev-install-helper.sh` is fully functional from a DerivedData build, so
    /// use `probe()` rather than this when deciding whether control is available.
    @discardableResult
    func refreshInstallationState() -> InstallationState {
        guard isInApplicationsFolder else {
            let state = InstallationState.unavailable(InstallationState.notInApplicationsReason)
            publish { self.installationState = state }
            return state
        }

        let service = SMAppService.daemon(plistName: HelperConstants.helperPlistName)
        let state: InstallationState
        switch service.status {
        case .enabled:
            state = .installed
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .notInstalled
        case .notFound:
            state = .unavailable("the LaunchDaemon plist is missing from the app bundle")
        @unknown default:
            state = .unknown
        }
        publish { self.installationState = state }
        return state
    }

    /// The authoritative check: ask the daemon directly.
    ///
    /// XPC first, because a daemon that answers is a daemon that works — however it got
    /// there (SMAppService, or a development `launchctl bootstrap`). SMAppService status
    /// and the `/Applications` requirement are only consulted to *explain* the absence
    /// of a daemon and to decide what the install button should do.
    @discardableResult
    func probe() async -> InstallationState {
        if let caps = await fetchCapabilities() {
            let state: InstallationState = caps.isRoot
                ? .installed
                : .unavailable("the daemon is running, but not as root")
            publish {
                self.installationState = state
                self.needsReinstall = caps.version != HelperConstants.helperVersion
                if caps.version != HelperConstants.helperVersion {
                    self.lastError = "Helper version \(caps.version) does not match the app's "
                        + "\(HelperConstants.helperVersion)."
                }
            }
            return state
        }

        // Nothing is answering. Distinguish "never installed" from "registered but unable to
        // start", because only the second one is a bug — and the only one this app can fix.
        //
        // "SMAppService says enabled" is deliberately part of this test and deliberately NOT
        // reported as installed. launchd submits the bundle's plist to BackgroundTaskManagement
        // together with a code requirement (LWCR) derived from the executable's signature.
        // Replacing the app bundle — every reinstall, and every rebuild of an ad-hoc-signed
        // build — changes that signature, and the requirement stops matching:
        //
        //     Requesting repair LWCR update … Unable to get updated LWCR … No such process
        //     job state = spawn failed        (exit 78, EX_CONFIG, retried every 10 s)
        //
        // launchd never starts the daemon again, so no client can ever reach it; the recorded
        // registration is all that is left. Claiming "installed" here hid that and turned it
        // into a confusing command failure later.
        //
        // The launchd job is the backstop for the case that matters most: a record whose
        // code requirement went stale can report "not found" (SMAppServiceStatusNotFound)
        // while launchd still holds the submitted job, so the status alone would conclude
        // there is nothing to repair.
        let launchdStillHasTheJob = await LaunchdJob.exists(label: HelperConstants.machServiceName)
        if hasRegisteredDaemonPlist || isRegisteredWithSMAppService || launchdStillHasTheJob {
            let state = InstallationState.unavailable(InstallationState.registeredButNotRespondingReason)
            publish {
                self.installationState = state
                self.lastError = "A daemon is registered but nothing answered on the Mach service. "
                    + "Either it is crashing on launch, or it is refusing this app's code "
                    + "signature — both look identical from here. Check with: "
                    + "launchctl print system/\(HelperConstants.machServiceName) and "
                    + "log show --last 5m --predicate 'process == \"AutoFansMacHelper\"'"
            }
            // Two very different causes produce this same silence. A signature refusal is the
            // nastier one: the daemon runs perfectly and rejects every connection, so the app
            // reports "not responding" while `launchctl` shows a healthy, running job.
            log?.warning("helper", "daemon registered at /Library/LaunchDaemons/"
                         + "\(HelperConstants.helperPlistName) but not answering — it may be "
                         + "crash-looping, or refusing this app's signature (see the daemon's "
                         + "\"auth\" log)")
            return state
        }

        // Never installed. Explain why, and what the user can do about it.
        return refreshInstallationState()
    }

    /// Registers the daemon. On macOS 13+ the system shows the admin prompt itself.
    func install() async -> Bool {
        guard isInApplicationsFolder else {
            // SMAppService would register the bundled plist verbatim, and that plist
            // points at /Applications — registering from here would install a daemon
            // that cannot start. Point the developer at the working alternative instead.
            let error = HelperError.appNotInApplications(bundlePath)
            publish {
                self.lastError = error.localizedDescription
                self.installationState = .unavailable(InstallationState.notInApplicationsReason)
            }
            log?.warning("helper", "install refused: \(error.localizedDescription)")
            return false
        }

        do {
            try registerDaemon()
            log?.info("helper", "registered \(HelperConstants.helperPlistName)")
        } catch {
            // Registering an already-registered daemon throws; that is not a failure.
            log?.warning("helper", "register() returned: \(error.localizedDescription)")
        }

        var state = refreshInstallationState()
        if state == .requiresApproval {
            // Deep-link the user to the approval switch.
            SMAppService.openSystemSettingsLoginItems()
            log?.warning("helper", "approval required — opened Login Items settings")
            // Give the user a moment, then re-check.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state = refreshInstallationState()
        }

        guard state == .installed else { return false }

        // Confirm over XPC that it actually runs as root.
        //
        // Retried, because registering a daemon does not make it answer instantly: launchd
        // still has to load the job, and the lookup immediately after registration can lose
        // that race. "Registered but not answering XPC" seconds after a successful install,
        // with a daemon that is in fact fine, is not something a user can act on.
        var capabilities: HelperCapabilities?
        for attempt in 0..<3 {
            capabilities = await fetchCapabilities(recordFailure: true)
            if capabilities != nil { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
        guard let caps = capabilities else {
            // Same state the probe reports, so the UI explains it once, in one place.
            publish { self.installationState = .unavailable(InstallationState.registeredButNotRespondingReason) }
            return false
        }
        guard caps.isRoot else {
            publish {
                self.installationState = .unavailable("the daemon is not running as root")
                self.lastError = "The helper answered, but it is not running as root."
            }
            return false
        }
        if caps.version != HelperConstants.helperVersion {
            publish {
                self.needsReinstall = true
                self.lastError = "Helper version \(caps.version) does not match the app's \(HelperConstants.helperVersion)."
            }
        }
        reconnectAttempts = 0
        return true
    }

    /// Unregisters the daemon after asking it to restore automatic fan control.
    func uninstall() async -> Bool {
        _ = await resetAllToAuto()
        closeConnection()

        do {
            try unregisterDaemon()
            log?.info("helper", "unregistered the daemon")
        } catch {
            publish { self.lastError = error.localizedDescription }
            log?.failure("helper", "unregister failed: \(error.localizedDescription)")
            return false
        }
        stopHeartbeat()
        // Deliberately uninstalled: the app must not put it back on the next launch.
        AppSettings.clearHelperHistory()
        refreshInstallationState()
        publish { self.capabilities = nil }
        return true
    }

    /// Unregister → register, used after an app update changes the helper binary.
    ///
    /// The `/Applications` check comes FIRST, and that ordering is the whole point: this used
    /// to unregister and then call `install()`, which refuses outside /Applications. The
    /// result was a removed LaunchDaemon, no way to re-register it from inside the app, and a
    /// developer left with no fan control — observed in the wild via
    /// `SMAppService … Unregister` at 23:56:16 followed by silence.
    ///
    /// Never destroy something you cannot put back.
    func reinstall() async -> Bool {
        guard isInApplicationsFolder else {
            let error = HelperError.appNotInApplications(bundlePath)
            publish { self.lastError = error.localizedDescription }
            log?.warning("helper", "reinstall refused outside /Applications — the installed daemon was left untouched")
            refreshInstallationState()
            return false
        }

        try? unregisterDaemon()
        closeConnection()
        publish { self.needsReinstall = false }
        return await install()
    }

    /// The one-line terminal command that installs the daemon WITHOUT SMAppService.
    ///
    /// Worth offering when SMAppService itself is the problem: this writes a plain
    /// LaunchDaemon and bootstraps it, so there is no BackgroundTaskManagement record and no
    /// code requirement to go stale when the app bundle is replaced. It needs one
    /// `sudo`, which is why the app cannot just do it silently.
    ///
    /// Nil when this build does not ship the installer — a plain Xcode build does not, and
    /// then this advice would be wrong.
    static func terminalInstallCommand(bundlePath: String) -> String? {
        let script = bundlePath + "/Contents/Resources/install-helper.sh"
        guard FileManager.default.fileExists(atPath: script) else { return nil }

        // The unsigned distribution compiles the daemon to accept untrusted clients, and its
        // bundled plist says so; the installer needs the matching flag.
        let plist = bundlePath + "/" + HelperConstants.helperBundleSubpath + "/" + HelperConstants.helperPlistName
        let environment = (NSDictionary(contentsOfFile: plist)?["EnvironmentVariables"]) as? [String: String]
        let untrusted = environment?["AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS"] != nil

        return "sudo \"\(script)\" install \"\(bundlePath)\"\(untrusted ? " --allow-untrusted" : "")"
    }

    /// True when reinstalling from inside the app can actually succeed.
    ///
    /// The UI must not offer a destructive "update the helper" action that can only fail.
    var canReinstallHelper: Bool {
        isInApplicationsFolder
    }

    // MARK: - Connection

    /// Guards the cached connection. XPC invalidation arrives on its own queue, so the
    /// cache cannot be cleared unsynchronised.
    private let connectionLock = NSLock()

    /// Builds a connection, wired so that a dead one is also *forgotten*.
    ///
    /// This is the fix for "registered but not answering XPC" after installing the helper.
    /// A connection created while the daemon does not exist yet is permanently invalid:
    /// XPC invalidation is terminal, and reusing the object fails every subsequent call
    /// with "Couldn't communicate with a helper application". The app kept that dead object
    /// cached, so nothing recovered until it was restarted. Now the next call builds a
    /// fresh connection and launchd starts the daemon on demand.
    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        // Captured weakly: the connection retains its handlers, so a strong capture here
        // would keep every dead connection alive forever.
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let self else { return }
            let hadDaemon = self.everConnected
            if let connection { self.discardConnection(connection) }
            self.publish { self.isConnected = false }
            if hadDaemon {
                self.log?.warning("helper", "XPC connection interrupted — the daemon went away")
            }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            let hadDaemon = self.everConnected
            if let connection { self.discardConnection(connection) }
            self.publish { self.isConnected = false }
            if hadDaemon {
                self.log?.warning("helper", "XPC connection invalidated — the daemon went away")
            }
        }
        connection.resume()
        return connection
    }

    /// Forgets a dead connection while it is still the cached one. Identity-checked, so a
    /// handler firing late cannot throw away a newer, working connection.
    private func discardConnection(_ dead: NSXPCConnection) {
        connectionLock.lock()
        if connection === dead { connection = nil }
        connectionLock.unlock()
    }

    private func currentConnection() -> NSXPCConnection {
        connectionLock.lock()
        if let connection {
            connectionLock.unlock()
            return connection
        }
        connectionLock.unlock()

        // Built outside the lock: resume() can reach a handler synchronously.
        let fresh = makeConnection()

        connectionLock.lock()
        if let existing = connection {
            connectionLock.unlock()
            fresh.invalidate()
            return existing
        }
        connection = fresh
        connectionLock.unlock()

        publish { self.isConnected = true }
        return fresh
    }

    func closeConnection() {
        connectionLock.lock()
        let dead = connection
        connection = nil
        connectionLock.unlock()
        dead?.invalidate()
        publish { self.isConnected = false }
    }

    /// Connects (if needed) and verifies the daemon answers.
    ///
    /// Always probes over XPC first (see `probe()`), so a development daemon installed
    /// with `Scripts/dev-install-helper.sh` works from an Xcode-run build.
    ///
    /// A daemon that is registered but which launchd refuses to start is repaired here,
    /// once per run. That is the state every replacement of the app bundle lands in (the
    /// LWCR mechanism is described in `probe()`), and the repair is the same thing the
    /// Install button does — re-registering makes the system record a requirement that
    /// matches the executable again. Without this the user has to press that button after
    /// every install, which is exactly what they had to do before.
    @discardableResult
    func connect() async -> Bool {
        var state = await probe()

        // Two ways to know the daemon *was* installed and is now unreachable. Either proof is
        // enough to repair without asking, because neither can be true on a machine that
        // never had a helper:
        //
        //   1. launchd still holds the submitted job (a registration whose code requirement
        //      went stale — the job exists but can never spawn), or
        //   2. the daemon has answered this app before, and now nothing at all is registered.
        let registrationIsGone = state == .notInstalled || state == .unknown
        let wasInstalledAndIsNowMissing = registrationIsGone && AppSettings.helperHasWorkedBefore

        if (state.isRegisteredButNotResponding || wasInstalledAndIsNowMissing),
           !hasAttemptedRegistrationRepair, isInApplicationsFolder {
            hasAttemptedRegistrationRepair = true
            log?.warning("helper", state.isRegisteredButNotResponding
                         ? "registered but launchd cannot start it — re-registering (what the "
                            + "Install button does)"
                         : "the daemon is gone but this Mac had one — re-registering (what the "
                            + "Install button does)")

            if await install() {
                state = .installed
            } else {
                // A record BackgroundTaskManagement has already lost cannot always be repaired
                // by registering over the top of it. Drop it and register again — the
                // "Reinstall helper" flow. `reinstall()` refuses outside /Applications, so
                // this can never leave the machine without a daemon it could not put back.
                log?.warning("helper", "re-registering did not take — replacing the registration")
                state = await reinstall() ? .installed : installationState
            }
        }

        if state == .installed { hasAttemptedRegistrationRepair = false }
        publish { self.isConnected = state == .installed }
        return state == .installed
    }

    // MARK: - Typed calls

    private final class ReplyBox<T> {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<T, Error>

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(with: result)
        }
    }

    /// Runs one XPC call with an error handler and a timeout.
    ///
    /// The timeout has to **resume the continuation**, not merely cancel the call or race it
    /// against a sleeping task. A task group cannot return until every child has finished,
    /// and a checked continuation that nobody resumes never finishes — so the obvious
    /// "sleep 10 s, then throw" version does not time out at all: it hangs, and everything
    /// awaiting it hangs with it. A registered-but-unspawnable daemon produces exactly that
    /// shape, because the Mach service still exists, so the message is accepted and simply
    /// never answered.
    ///
    /// The symptom was expensive to find precisely because it looks like nothing at all:
    /// `connect()` never returned, so the installation state was never updated and the app
    /// sat on its initial "Checking…" — at launch, and for ever, because the poll loop that
    /// would have retried starts at the end of that same code path. The real fault (a stale
    /// SMAppService code requirement) could not be seen, let alone repaired.
    private func call<T>(
        timeout: TimeInterval,
        _ operation: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async throws -> T {
        let connection = currentConnection()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let box = ReplyBox(continuation)

            // Detached, so nothing waits on it. ReplyBox ignores a second finish, which is
            // what makes a reply that arrives after the timeout harmless.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.finish(.failure(HelperError.timedOut(seconds: timeout)))
            }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.finish(.failure(HelperError.connectionFailed(error.localizedDescription)))
            }) as? HelperProtocol else {
                box.finish(.failure(HelperError.replyFailed))
                return
            }
            operation(proxy) { value in box.finish(.success(value)) }
        }
    }

    /// - Parameter recordFailure: pass true only when a daemon is *expected* (i.e. right
    ///   after an install attempt). A routine probe of an uninstalled helper is normal.
    func fetchCapabilities(recordFailure: Bool = false) async -> HelperCapabilities? {
        do {
            // A live daemon answers this in milliseconds; the fan commands below are the
            // calls that legitimately need a long timeout. Keeping this short bounds the
            // launch-time registration repair, which may have to wait out several probes.
            let data = try await call(timeout: 5) { proxy, reply in
                proxy.capabilities(reply: reply)
            }
            let caps = HelperCoding.decode(HelperCapabilities.self, from: data)
            if caps != nil {
                everConnected = true
                // The daemon answered, so this machine has one installed. Remembered across
                // launches: see AppSettings.helperHasWorkedBefore.
                AppSettings.markHelperWorked()
            }
            publish {
                self.capabilities = caps
                self.isConnected = caps != nil
                if let caps, caps.version == HelperConstants.helperVersion {
                    self.needsReinstall = false
                }
            }
            return caps
        } catch {
            let hadDaemon = everConnected
            publish {
                self.isConnected = false
                self.lastError = error.localizedDescription
            }
            if recordFailure || hadDaemon {
                log?.failure("helper", "capabilities failed: \(error.localizedDescription)")
            } else {
                log?.info("helper", "no daemon answering — fan control is not set up")
            }
            return nil
        }
    }

    /// A three-value XPC reply collapsed into one value so it can flow through the
    /// generic `call` (an @objc reply with three parameters is not a single-value
    /// closure).
    private struct ApplyReply {
        var success: Bool
        var message: String?
        var statuses: Data?
    }

    private struct ResetReply {
        var success: Bool
        var message: String?
    }

    /// Sends a complete desired fan vector. Generous timeout: the M3/M4 unlock can
    /// legitimately take ~30 s.
    func applyFanStates(_ payloads: [FanCommandPayload]) async -> Result<[FanCommandStatus], HelperError> {
        guard installationState.isUsable else {
            return .failure(installationState.preconditionError(bundlePath: bundlePath))
        }
        let json = HelperCoding.encode(payloads)
        do {
            let reply: ApplyReply = try await call(timeout: 60) { proxy, done in
                proxy.applyFanStates(json) { success, message, statusData in
                    done(ApplyReply(success: success, message: message, statuses: statusData))
                }
            }
            let statuses: [FanCommandStatus] = reply.statuses.flatMap {
                HelperCoding.decode([FanCommandStatus].self, from: $0)
            } ?? []
            if reply.success {
                return .success(statuses)
            }
            return .failure(.daemonReported(reply.message ?? "The helper refused the fan command."))
        } catch let error as HelperError {
            return .failure(error)
        } catch {
            return .failure(.connectionFailed(error.localizedDescription))
        }
    }

    func resetAllToAuto() async -> Result<Void, HelperError> {
        guard installationState.isUsable else { return .success(()) }
        do {
            let reply: ResetReply = try await call(timeout: 30) { proxy, done in
                proxy.resetAllToAuto { success, message in
                    done(ResetReply(success: success, message: message))
                }
            }
            return reply.success
                ? .success(())
                : .failure(.daemonReported(reply.message ?? "The helper could not restore automatic control."))
        } catch let error as HelperError {
            return .failure(error)
        } catch {
            return .failure(.connectionFailed(error.localizedDescription))
        }
    }

    @discardableResult
    func sendHeartbeat() async -> Bool {
        guard installationState.isUsable else { return false }
        do {
            let alive: Bool = try await call(timeout: 10) { proxy, reply in
                proxy.heartbeat(reply: reply)
            }
            return alive
        } catch {
            log?.warning("helper", "heartbeat failed: \(error.localizedDescription)")
            return false
        }
    }

    func fetchStatus() async -> HelperStatus? {
        guard installationState.isUsable else { return nil }
        do {
            let data: Data = try await call(timeout: 10) { proxy, reply in
                proxy.status(reply: reply)
            }
            return HelperCoding.decode(HelperStatus.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchEvents() async -> [FanControlEvent] {
        guard installationState.isUsable else { return [] }
        do {
            let data: Data = try await call(timeout: 10) { proxy, reply in
                proxy.recentEvents(reply: reply)
            }
            return HelperCoding.decode([FanControlEvent].self, from: data) ?? []
        } catch {
            return []
        }
    }

    // MARK: - Heartbeat

    /// Starts the 15 s dead-man ping. The helper resets fans after 60 s of silence
    /// (§6.7.4), so this must keep running while any fan is manual.
    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + HelperConstants.heartbeatInterval,
                       repeating: HelperConstants.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.sendHeartbeat() }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Helpers

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

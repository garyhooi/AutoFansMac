//
//  SettingsView.swift
//  AutoFansMac
//
//  PROMPT.md §6.6. General preferences, the helper install/uninstall flow, and the
//  expert section (collapsed by default) that holds the genuinely dangerous switches.
//

import SwiftUI
import ServiceManagement
import SMCKit

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// Used to ask SwiftUI for the window again if the Dock switch takes it down.
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKey.showInDock) private var showInDock = false
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(SettingsKey.pollingInterval) private var pollingInterval = PollingInterval.one.rawValue
    @AppStorage(SettingsKey.menuBarContent) private var menuBarContent = MenuBarContent.hottestCPU.rawValue
    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin = false
    @AppStorage(SettingsKey.restoreFansOnQuit) private var restoreFansOnQuit = true
    @AppStorage(SettingsKey.allowUnsafeFanTargets) private var allowUnsafeTargets = false
    @AppStorage(SettingsKey.minimumRPMDelta) private var minimumRPMDelta = 50.0
    @AppStorage(SettingsKey.thermalFloorEnabled) private var thermalFloorEnabled = true
    @AppStorage(SettingsKey.thermalFloorCelsius) private var thermalFloorCelsius = SafetyBounds.defaultThermalFloor
    @AppStorage(SettingsKey.thermalStateOverrideEnabled) private var thermalStateOverride = true
    @AppStorage(SettingsKey.showUnknownSensors) private var showUnknownSensors = true
    @AppStorage(SettingsKey.checkForUpdatesAutomatically) private var checkForUpdates = true

    @State private var showingUnsafeConfirmation = false
    @State private var isWorkingOnHelper = false
    @State private var helperMessage: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            fanControl.tabItem { Label("Fan Control", systemImage: "fan") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
        .navigationTitle("Settings")
        .onChange(of: showInDock) { newValue in
            applyDockVisibility(newValue)
        }
        .onChange(of: pollingInterval) { newValue in
            deferToNextRunLoop { env.setPollingInterval(newValue) }
        }
        .onChange(of: launchAtLogin) { newValue in
            deferToNextRunLoop { updateLaunchAtLogin(newValue) }
        }
        .onChange(of: checkForUpdates) { newValue in
            // Switching it on should answer the question immediately, not tomorrow.
            guard newValue else { return }
            deferToNextRunLoop { Task { await env.updates.check() } }
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Appearance") {
                Picker("Temperature unit", selection: $temperatureUnitRaw) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius.rawValue)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                Picker("Menu bar shows", selection: $menuBarContent) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.displayName).tag(content.rawValue)
                    }
                }
                Toggle("Show AutoFansMac in the Dock", isOn: $showInDock)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Polling") {
                Picker("Refresh interval", selection: $pollingInterval) {
                    ForEach(PollingInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval.rawValue)
                    }
                }
                Text("The full sensor sweep runs at launch and on demand; each tick refreshes the "
                     + "sensors a curve tracks plus every fan, which keeps idle CPU use around 1 %.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sensors") {
                Toggle("Show sensors that are not in the catalog", isOn: $showUnknownSensors)
                Text("Unknown keys appear in the Sensors view under “Unknown” with their raw SMC key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Fan control

    private var fanControl: some View {
        Form {
            Section("Privileged helper") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(env.helper.installationState.isUsable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(env.helper.installationState.displayName)
                    }
                }
                LabeledContent("Details") {
                    Text(env.helperStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !env.helper.isInApplicationsFolder {
                    Label("Running from \(env.helper.bundlePath). For fan control either move the app to "
                          + "/Applications, or install the development daemon with "
                          + "`sudo Scripts/dev-install-helper.sh install` and press Reconnect. "
                          + "Sensor monitoring needs neither.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if env.helper.installationState.isUsable {
                        // Disabled rather than hidden: the button needs to explain itself, and
                        // it would unregister a daemon this app cannot register back.
                        Button("Reinstall helper") { reinstallHelper() }
                            .disabled(isWorkingOnHelper || !env.helper.canReinstallHelper)
                            .help(env.helper.canReinstallHelper
                                  ? "Replace the installed helper with this build's"
                                  : "Only available when AutoFansMac runs from /Applications")
                        Button("Uninstall helper") { uninstallHelper() }
                            .disabled(isWorkingOnHelper)
                    } else {
                        // Registering only makes sense from /Applications; elsewhere the
                        // route is the development daemon plus Reconnect.
                        if env.helper.isInApplicationsFolder {
                            Button("Install helper") { installHelper() }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorkingOnHelper)
                        } else {
                            Button("Copy dev install command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "sudo Scripts/dev-install-helper.sh install", forType: .string)
                                helperMessage = "Command copied — run it in Terminal from the repository root."
                            }
                        }
                        if env.helper.installationState == .requiresApproval {
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    Button("Reconnect") { reconnectHelper() }
                        .disabled(isWorkingOnHelper)
                    if isWorkingOnHelper { ProgressView().controlSize(.small) }
                }
                if let helperMessage {
                    Text(helperMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("The administrator password is requested only when the helper is installed or updated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Lifecycle") {
                Toggle("Restore fans to Automatic when AutoFansMac quits", isOn: $restoreFansOnQuit)
                if !restoreFansOnQuit {
                    Label("With this off, a custom fan mode survives quitting AutoFansMac — macOS will "
                          + "keep the last commanded RPM until something else takes over. "
                          + "The helper still restores Automatic if the app dies (dead-man switch, 60 s).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Safety") {
                Toggle("Thermal floor override", isOn: $thermalFloorEnabled)
                HStack {
                    Text("Floor")
                    Slider(value: $thermalFloorCelsius,
                           in: SafetyBounds.thermalFloorRange,
                           step: 1)
                    Text("\(Int(thermalFloorCelsius)) °C")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!thermalFloorEnabled)
                Toggle("Also override when macOS reports a serious thermal state", isOn: $thermalStateOverride)
                Text("When any CPU, GPU or SOC sensor reaches the floor, every fan is driven to its "
                     + "maximum, whatever profile is active. Normal control resumes once temperatures "
                     + "fall \(Int(SafetyBounds.thermalFloorHysteresis)) °C below the floor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                DisclosureGroup("Expert options") {
                    // A plain $ binding: the previous hand-rolled one did not round-trip
                    // (it refused to store `true`, only raising an alert), and SwiftUI
                    // invoking such a setter during a view update mutates @State mid-update
                    // — "Publishing changes from within view updates is not allowed".
                    // Now the switch follows the value and the alert confirms afterwards.
                    Toggle("Allow fan targets outside the fan's rated range", isOn: $allowUnsafeTargets)
                    Text("The firmware happily accepts 0 RPM (the fan stops) and values above the rated "
                         + "maximum. This switch is reset every launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Minimum RPM change before a write")
                        Slider(value: $minimumRPMDelta, in: 25...200, step: 5)
                        Text("\(Int(minimumRPMDelta)) RPM").monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    Text("Smaller values track temperature more closely at the cost of more SMC writes. "
                         + "Writes are always at least 1 s apart per fan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Deferred: this writes @State, and onChange runs inside a view update.
        .onChange(of: allowUnsafeTargets) { newValue in
            guard newValue else { return }
            deferToNextRunLoop { showingUnsafeConfirmation = true }
        }
        .alert("Allow unsafe fan targets?", isPresented: $showingUnsafeConfirmation) {
            // Cancel puts it back; confirming just dismisses (the value is already stored).
            Button("Cancel", role: .cancel) { allowUnsafeTargets = false }
            Button("I understand the risk", role: .destructive) { }
        } message: {
            Text("Fan minimum and maximum values are guidelines, not hard limits. Allowing targets "
                 + "outside them can stop a fan completely or over-drive it, which risks overheating "
                 + "and hardware damage. This setting lasts only for this session.")
        }
    }

    // MARK: - About

    private var about: some View {
        Form {
            Section("AutoFansMac") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                }
                LabeledContent("Helper") {
                    Text(HelperConstants.helperVersion)
                }
                LabeledContent("Hardware") {
                    Text("\(env.platform.modelIdentifier) · \(env.platform.chipName)")
                }
                LabeledContent("Unlock style") {
                    Text(env.fans.snapshot.unlockStyle.rawValue)
                }
                LabeledContent("Source") {
                    Button {
                        _ = NSWorkspace.shared.open(AppLinks.repository)
                    } label: {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                    }
                    .help("Open \(AppLinks.repository.absoluteString) in the browser")
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                LabeledContent("Latest release") {
                    HStack(spacing: 8) {
                        Text(updateSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(updateActionTitle) { updateAction() }
                            .disabled(env.updates.state.isChecking)
                    }
                }
            }

            Section("Privacy") {
                Text("Sensors and fans stay on this Mac. The update check is the only network "
                     + "request the app makes — one plain GitHub lookup for the latest release, "
                     + "which sends nothing about you or this machine — and it can be switched "
                     + "off above. Everything else works offline.")
                    .font(.callout)
            }

            Section("Credits") {
                Text("Sensor naming data is derived from the Stats project by Serhiy Mytrovtsiy (MIT licence).")
                    .font(.callout)
                Text("Fan-control behaviour is based on public reverse-engineering research "
                     + "(macos-smc-fan) and the documented AppleSMC interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Files") {
                LabeledContent("Profiles") {
                    Text(ProfileStore.profilesURL.path).font(.caption).textSelection(.enabled)
                }
                LabeledContent("Diagnostics") {
                    Button("Export Diagnostics…") { exportDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Updates

    /// One line for the About tab; the state machine itself lives in `UpdateChecker`.
    private var updateSummary: String {
        switch env.updates.state {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .noReleases: return "No releases published yet"
        case .upToDate(let version): return "Up to date (\(version))"
        case .available(let release): return "\(release.version) is available"
        case .failed(let message): return message
        }
    }

    private var updateActionTitle: String {
        switch env.updates.state {
        case .checking: return "Checking…"
        case .available(let release):
            return release.downloadURL == nil ? "Release notes" : "Download \(release.version)"
        default: return "Check Now"
        }
    }

    /// One button, two jobs: a new release opens the download, otherwise it checks.
    private func updateAction() {
        switch env.updates.state {
        case .available(let release):
            _ = NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
        default:
            Task { await env.updates.check() }
        }
    }

    // MARK: - Actions

    /// "Show AutoFansMac in the Dock" changes the Dock tile and nothing else.
    ///
    /// Leaving `.regular` for `.accessory` also deactivates the app, and the window the
    /// user is looking at (this very screen) must survive that: it is noted before the
    /// policy change and restored after, and if macOS really did take it down, SwiftUI is
    /// asked to open the scene again.
    private func applyDockVisibility(_ visible: Bool) {
        let wasPresenting = MainWindow.isPresented
        deferToNextRunLoop {
            DockVisibility.setShownInDock(visible)
            guard !visible, wasPresenting, !MainWindow.isPresented else { return }
            openWindow(id: MainWindow.sceneID)
            DispatchQueue.main.async { MainWindow.present() }
        }
    }

    private func installHelper() {
        isWorkingOnHelper = true
        helperMessage = nil
        Task { @MainActor in
            let ok = await env.helper.install()
            isWorkingOnHelper = false
            env.refreshHelperBanner()
            helperMessage = ok
                ? "Helper installed and answering."
                : env.helper.lastError ?? "The helper could not be installed."
        }
    }

    private func reinstallHelper() {
        isWorkingOnHelper = true
        helperMessage = nil
        Task { @MainActor in
            let ok = await env.helper.reinstall()
            isWorkingOnHelper = false
            env.refreshHelperBanner()
            helperMessage = ok ? "Helper reinstalled." : env.helper.lastError ?? "Reinstall failed."
        }
    }

    private func uninstallHelper() {
        isWorkingOnHelper = true
        helperMessage = nil
        Task { @MainActor in
            _ = await env.fans.restoreAllToAuto(reason: "helper uninstall")
            let ok = await env.helper.uninstall()
            isWorkingOnHelper = false
            env.refreshHelperBanner()
            helperMessage = ok ? "Helper removed; fans are back under macOS control." : env.helper.lastError
        }
    }

    private func reconnectHelper() {
        isWorkingOnHelper = true
        helperMessage = nil
        Task { @MainActor in
            await env.reconnectHelper()
            isWorkingOnHelper = false
            helperMessage = env.helper.installationState.isUsable
                ? "Connected: \(env.helperStatusSummary)"
                : "Still no daemon answering — \(env.helper.installationState.displayName)."
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            env.log.info("app", "launch at login \(enabled ? "enabled" : "disabled")")
        } catch {
            env.log.warning("app", "launch at login change failed: \(error.localizedDescription)")
        }
    }

    private func exportDiagnostics() {
        Task { @MainActor in
            let report = await env.buildDiagnosticsReport()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "AutoFansMac-diagnostics-\(Self.stamp()).txt"
            panel.allowedContentTypes = [.plainText]
            panel.title = "Export AutoFansMac Diagnostics"
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try report.write(to: url, atomically: true, encoding: .utf8)
                    env.log.info("diagnostics", "exported to \(url.path)")
                } catch {
                    env.log.failure("diagnostics", "export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

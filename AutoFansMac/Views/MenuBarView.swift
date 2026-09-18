//
//  MenuBarView.swift
//  AutoFansMac
//
//  The MenuBarExtra dropdown (PROMPT.md §6.5): per-fan compact rows, one-click profile
//  switching, the two quick actions, and the app menu.
//

import SwiftUI
import SMCKit

/// The menu-bar item's label: a fan symbol plus the user's chosen readout.
struct MenuBarLabel: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: env.safety.state.isOverriding ? "exclamationmark.triangle.fill" : "fan.fill")
            if let text = readout {
                Text(text).monospacedDigit()
            }
        }
        .help(helpText)
    }

    private var readout: String? {
        let content = AppSettings.menuBarContent
        switch content {
        case .iconOnly:
            return nil

        case .fastestFan:
            let rpm = env.fans.snapshot.fans.map(\.currentRPM).max() ?? 0
            return "\(Int(rpm))"

        case .selectedSensor:
            guard let first = env.fans.desiredSettings.first(where: { $0.mode == .sensor })?.sensorKey,
                  let sample = env.sensors.sample(forKey: first) else { return nil }
            return temperature(sample)

        case .hottestCPU, .averageCPU, .hottestGPU, .averageGPU:
            // The aggregate normally exists; the group's plain sensors are the fallback for
            // the first tick, before the computed rows have been published.
            guard let sample = env.sensors.sample(forKey: content.sensorKey ?? "")
                    ?? env.sensors.temperatureSamples.first(where: { $0.group == content.sensorGroup }) else {
                return nil
            }
            return temperature(sample)
        }
    }

    private func temperature(_ sample: SensorSample) -> String {
        String(format: "%.0f°", AppSettings.temperatureUnit.convert(sample.rawValue))
    }

    /// Names whatever the label is showing, so the number has a subject even when the user
    /// picked an aggregate other than "CPU hottest".
    private var helpText: String {
        let content = AppSettings.menuBarContent
        guard let key = content.sensorKey else { return "AutoFansMac — \(content.displayName)" }
        let value = env.sensors.sample(forKey: key).map { String(format: "%.1f °C", $0.rawValue) } ?? "n/a"
        return "AutoFansMac — \(content.displayName): \(value)"
    }
}

/// The MenuBarExtra dropdown.
///
/// Observes `MenuBarModel`, **not** `AppEnvironment`, and shows nothing that changes on every
/// poll. Both matter: re-evaluating this content rebuilds the `NSMenu` behind it and closes any
/// open submenu, which is what made the mode picker impossible to use — the menu flashed once a
/// second while the user was trying to click.
///
/// The environment is held as a plain reference (not `@EnvironmentObject`) so its constant stream
/// of publications cannot invalidate this view; it is here for the actions only.
struct MenuBarView: View {
    let environment: AppEnvironment
    @ObservedObject var model: MenuBarModel
    /// SwiftUI's "show me that window" action; see `presentMainWindow()`.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Per-fan rows: name and mode only. The live RPM is in the menu-bar title (Settings →
        // Menu bar shows) and in the main window.
        ForEach(model.fanRows) { row in
            Menu {
                Picker("Mode", selection: Binding(
                    get: { row.mode },
                    set: { newMode in
                        Task { @MainActor in
                            await environment.setFanMode(newMode, fanIndex: row.id)
                        }
                    }
                )) {
                    ForEach(FanControlMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Divider()
                Button("Full blast") {
                    Task { @MainActor in _ = await environment.fans.setFullBlast(fanIndex: row.id) }
                }
                Button("Automatic") {
                    Task { @MainActor in await environment.setFanMode(.auto, fanIndex: row.id) }
                }
            } label: {
                Text(row.title)
            }
        }

        if model.fanRows.isEmpty {
            Text("No fans detected")
        }

        Divider()

        Menu("Profiles") {
            ForEach(model.profiles) { profile in
                // A plain Text label: NSMenu items are happiest with a single string, and a
                // conditional HStack inside a menu item is asking for trouble.
                Button {
                    Task { @MainActor in await environment.activateProfile(id: profile.id) }
                } label: {
                    Text(profile.id == model.activeProfileID ? "\(profile.name)  ✓" : profile.name)
                }
            }
        }

        Button("Automatic") {
            Task { @MainActor in await environment.setAutomatic() }
        }
        Button("Full Blast") {
            Task { @MainActor in await environment.setFullBlast() }
        }

        Divider()

        if model.safetyOverride {
            Text("⚠︎ \(environment.safety.state.displayName)")
        }

        Button("Open AutoFansMac…") { presentMainWindow() }
            .keyboardShortcut("o")

        Button("Settings…") {
            environment.selection = .settings
            presentMainWindow()
        }
        .keyboardShortcut(",")

        Button("Export Diagnostics…") { exportDiagnostics() }

        Divider()

        Button("Quit AutoFansMac") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Brings the window back.
    ///
    /// `MainWindow.present()` fronts the window this app ordered out at launch — which the
    /// old one-liner could not find, because it looked for `canBecomeMain` and AppKit
    /// reports false for that while a window is hidden. `openWindow(id:)` covers the other
    /// case, a window the user actually closed and SwiftUI therefore has to re-create.
    ///
    /// The Dock icon deliberately stays as the user set it: this button opens the window,
    /// it is not a Dock preference.
    private func presentMainWindow() {
        guard !MainWindow.present() else { return }
        // There is no window to front — the user closed it — so ask SwiftUI for one. It is
        // created on a later run-loop turn, hence the second pass. `openWindow` is only
        // reached in this case on purpose: with a window already present it could open a
        // second one, and WindowGroup is happy to do that.
        openWindow(id: MainWindow.sceneID)
        DispatchQueue.main.async { MainWindow.present() }
    }

    private func exportDiagnostics() {
        Task { @MainActor in
            let report = await environment.buildDiagnosticsReport()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "AutoFansMac-diagnostics.txt"
            panel.allowedContentTypes = [.plainText]
            if panel.runModal() == .OK, let url = panel.url {
                try? report.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

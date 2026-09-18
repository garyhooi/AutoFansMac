//
//  AutoFansMacApp.swift
//  AutoFansMac
//
//  Application entry point: a MenuBarExtra (the primary surface, LSUIElement = true) plus
//  the main window, and the lifecycle duties that must happen on quit
//  (PROMPT.md §6.5, §6.7.3).
//

import SwiftUI
import AppKit
import SMCKit

@main
struct AutoFansMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The window is a configuration/monitoring surface; the app is a menu-bar utility.
        // The id is what the menu bar's "Open AutoFansMac…" / "Settings…" pass to
        // `openWindow(id:)` to bring the window back (see MainWindow).
        WindowGroup("AutoFansMac", id: MainWindow.sceneID) {
            ContentView()
                .environmentObject(delegate.environment)
                .frame(minWidth: 780, minHeight: 520)
                .sheet(isPresented: Binding(
                    get: { delegate.environment.showOnboarding },
                    set: { delegate.environment.showOnboarding = $0 }
                )) {
                    OnboardingView(onFinish: { delegate.environment.showOnboarding = false })
                        .environmentObject(delegate.environment)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit AutoFansMac") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .appInfo) {
                Button("Copy Diagnostics to Clipboard") {
                    Task { @MainActor in
                        let report = await delegate.environment.buildDiagnosticsReport()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                }
            }
        }

        MenuBarExtra {
            // The dropdown observes the quiet model; only the label observes the environment,
            // because the label is a status-item view and may update freely.
            MenuBarView(environment: delegate.environment, model: delegate.menuBarModel)
        } label: {
            MenuBarLabel()
                .environmentObject(delegate.environment)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the environment so that startup happens even when no window has been opened yet
/// (a menu-bar-only app must not depend on a view appearing before it starts polling).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    let environment = AppEnvironment()

    /// Backs the dropdown; see MenuBarModel for why it is separate from the environment.
    lazy var menuBarModel = MenuBarModel(environment: environment)

    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted by this app, so `xcodebuild test` would otherwise start
        // the real thing: connect to the privileged helper, apply the active profile (i.e.
        // command the developer's fans) and rewrite the user's profiles.json.
        guard !TestEnvironment.isRunningTests else {
            NSLog("[AutoFansMac] running under XCTest — the app will not start or touch hardware")
            return
        }

        // Menu-bar first: no Dock icon unless the user asks for one. DockVisibility also
        // supplies the icon, which AppKit does not do for an app that starts as an accessory.
        DockVisibility.apply()

        if !UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedOnboarding) {
            environment.showOnboarding = true
        } else if !AppSettings.showInDock {
            // Launched as a background utility: keep the window closed until asked for.
            // "Closed" means ordered out and still in `NSApp.windows`, so MainWindow can
            // bring it back — note that after the orderOut its `canBecomeMain` is false.
            DispatchQueue.main.async {
                for window in MainWindow.candidates where window.isVisible {
                    window.orderOut(nil)
                }
            }
        }

        Task { @MainActor in
            await environment.start()
            environment.log.info("app", "startup complete (helper: \(environment.helper.installationState.displayName))")
        }
    }

    /// Restore-on-quit needs to finish before the process exits, so termination is
    /// deferred until the reset command has been answered.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        Task { @MainActor in
            await environment.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        // Safety net: never hang the quit for more than 5 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    /// Double-clicking the app in the Finder (and the Dock tile, when it has one).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.present() }
        return true
    }
}

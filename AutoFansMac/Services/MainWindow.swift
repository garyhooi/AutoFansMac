//
//  MainWindow.swift
//  AutoFansMac
//
//  Finding and presenting the app's one window.
//
//  The window belongs to SwiftUI's `WindowGroup`, but the app opens as a menu-bar
//  utility: `AppDelegate` orders the window out at launch when the Dock icon is off.
//  That is exactly where the obvious "front the window" loop stops working —
//
//      for window in NSApp.windows where window.canBecomeMain { … }
//
//  AppKit reports `canBecomeMain == false` for as long as a window is **not visible**,
//  so after that `orderOut` the filter matched nothing and "Open AutoFansMac…",
//  "Settings…" and the Finder reopen path all did precisely nothing.
//
//  Windows are therefore found by shape instead: titled, able to become key, and
//  neither a panel nor a sheet. The status-item windows fail the same test, because
//  they cannot become key.
//

import AppKit

enum MainWindow {

    /// Must match the `WindowGroup` id in `AutoFansMacApp` — that is what
    /// `openWindow(id:)` re-opens when the user has closed the window for real.
    static let sceneID = "main"

    /// Every window that can host the app's UI: never a status-item window, panel or sheet.
    static var candidates: [NSWindow] {
        NSApp.windows.filter { isAppWindow($0) }
    }

    /// True while the app is showing its window.
    static var isPresented: Bool {
        candidates.contains { $0.isVisible && !$0.isMiniaturized }
    }

    /// Brings the window back: un-hides the app, restores a minimised window, fronts it.
    ///
    /// - Returns: false when there is no window to show at all — the user closed it, and
    ///   the caller's cue is to ask SwiftUI for one with `openWindow(id:)`.
    @discardableResult
    static func present() -> Bool {
        NSApp.unhide(nil)
        let windows = candidates
        guard !windows.isEmpty else { return false }

        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// The shape test.
    ///
    /// Deliberately *not* `canBecomeMain`: AppKit answers false for that flag while the
    /// window is hidden, which is the one window this app has to bring back.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !(window is NSPanel)
            && !window.isSheet
            && window.canBecomeKey
    }
}

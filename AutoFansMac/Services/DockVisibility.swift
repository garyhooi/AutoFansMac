//
//  DockVisibility.swift
//  AutoFansMac
//
//  The "Show AutoFansMac in the Dock" setting (Settings → General).
//
//  The icon has to be handed to AppKit explicitly, and that is not obvious from the API.
//  This app starts as an *accessory* (\`LSUIElement\`), which has no Dock tile at all, so
//  AppKit never loads an app icon into \`NSApplication.applicationIconImage\`. Switching the
//  activation policy to \`.regular\` at runtime creates the tile but does not backfill the
//  image, so the tile comes up wearing the generic application icon — the bundle's own
//  icon is never consulted, however correct it is. Setting the image first fixes it.
//

import AppKit

enum DockVisibility {

    /// Apply the user's preference for this launch: policy *and* icon together.
    static func apply() {
        setActivationPolicy(AppSettings.showInDock)
    }

    /// The Settings switch.
    ///
    /// This is the whole job of the setting: whether the app has a Dock tile. It must not
    /// touch the window, and dropping `.regular` has a second effect — the app is
    /// deactivated — which is easy to mistake for the window being closed. So the window
    /// the user had open is noted first and put back in front afterwards.
    static func setShownInDock(_ visible: Bool) {
        let wasPresenting = MainWindow.isPresented
        setActivationPolicy(visible)
        guard !visible, wasPresenting else { return }
        MainWindow.present()
    }

    /// Policy *and* icon together.
    private static func setActivationPolicy(_ visibleInDock: Bool) {
        if visibleInDock, let icon = bundleIcon {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(visibleInDock ? .regular : .accessory)
    }

    /// The app icon as compiled from \`Assets.xcassets/AppIcon.appiconset\`.
    ///
    /// The asset catalog is the source of truth; the bundle's generated \`AppIcon.icns\` is a
    /// legacy fallback (it only carries the smaller representations).
    private static var bundleIcon: NSImage? {
        // Three names, because which one resolves depends on how the icon was compiled:
        // "NSApplicationIcon" is the documented one, the asset-catalog name works on
        // current toolchains, and the generated .icns is the legacy fallback. The system
        // is asked last, so a Dock tile is always handed *something* real.
        for name in [NSImage.applicationIconName, "AppIcon"] {
            if let image = NSImage(named: name) {
                NSLog("[AutoFansMac] Dock icon from NSImage(named: \(name))")
                return image
            }
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSLog("[AutoFansMac] Dock icon from the bundled AppIcon.icns")
            return image
        }
        NSLog("[AutoFansMac] Dock icon fell back to the workspace icon for the bundle")
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}

// swift-tools-version: 5.9
//
//  Package.swift
//  SMCKit — the hardware layer for AutoFansMac.
//
//  Contains ALL AppleSMC access (IOKit), value codecs, fan probing, the
//  per-generation unlock state machine, and the sensor catalog/scanner.
//  Deliberately has no UI and no AppKit/SwiftUI dependency so that the app,
//  the privileged helper and the afmctl CLI can all link the exact same code.
//
//  Zero third-party runtime dependencies by design (reviewability + notarization).
//

import PackageDescription

let package = Package(
    name: "SMCKit",
    platforms: [
        // MenuBarExtra / SMAppService / Swift Charts in the app; SMCKit itself
        // only needs 13.0 for the modern concurrency APIs it uses.
        .macOS(.v13)
    ],
    products: [
        // Two products from one target, and the split is load-bearing.
        //
        // `SMCKit` (dynamic) is what the app and its hosted test bundle link. Both run in
        // one process, so a *static* library would be duplicated between the app and the
        // test bundle — Xcode rejects that outright ("Swift package product
        // 'SMCKit-product' is linked as a static library by 'AutoFansMacTests' and
        // 'AutoFansMac'. This will result in duplication of library code."). A dynamic
        // framework is shared by both, and Xcode embeds it into the app bundle.
        //
        // `SMCKitStatic` is what the privileged helper links. The helper is a *tool* that
        // gets copied out of the app bundle into /Library/PrivilegedHelperTools, so it
        // must be self-contained: with a dynamic product it would carry an @rpath into
        // DerivedData/PackageFrameworks and crash-loop in dyld (launchd reports
        // `OS_REASON_DYLD`, "Library not loaded: @rpath/SMCKit_…_PackageProduct").
        //
        // Never collapse these into one product: whichever linkage you pick, the other
        // consumer breaks. Scripts/dev-install-helper.sh, Scripts/package-dmg.sh and CI
        // all verify the helper has no non-system dependencies.
        .library(name: "SMCKit", type: .dynamic, targets: ["SMCKit"]),
        .library(name: "SMCKitStatic", type: .static, targets: ["SMCKit"])
    ],
    targets: [
        .target(
            name: "SMCKit",
            swiftSettings: [.define("SMCKIT_FRAMEWORK")]
        ),
        .testTarget(
            name: "SMCKitTests",
            dependencies: ["SMCKit"]
        )
    ],
    swiftLanguageVersions: [.v5]
)

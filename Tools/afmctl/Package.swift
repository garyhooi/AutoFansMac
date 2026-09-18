// swift-tools-version: 5.9
//
//  Package.swift
//  afmctl — the AutoFansMac hardware QA command-line tool.
//
//  Deliberately a separate SwiftPM package that depends on the local SMCKit package,
//  so it can be built and run without Xcode: `swift run afmctl fans`.
//  Hand-rolled argument parsing keeps the zero-dependency rule intact.
//

import PackageDescription

let package = Package(
    name: "afmctl",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/SMCKit")
    ],
    targets: [
        .executableTarget(
            name: "afmctl",
            dependencies: [.product(name: "SMCKit", package: "SMCKit")]
        )
    ],
    swiftLanguageVersions: [.v5]
)

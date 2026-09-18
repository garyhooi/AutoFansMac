//
//  TestEnvironment.swift
//  AutoFansMac
//
//  Detects an XCTest host process.
//
//  The unit-test bundle is *hosted* by the app, so `xcodebuild test` launches the real
//  application: `applicationDidFinishLaunching` fires, the app connects to the privileged
//  helper and applies the active profile — commanding the developer's actual fans — and
//  anything that persists state (profiles, preferences) writes to the real locations.
//
//  Both are unacceptable side effects of running the test suite, so the app checks this and
//  stays inert under test.
//

import Foundation

enum TestEnvironment {

    /// True when this process is an XCTest host.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner for the process under test;
    /// the class check covers the case where XCTest has already been loaded into it.
    static var isRunningTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    /// A scratch directory for anything the app would otherwise persist to the user's home
    /// while running under test. Keyed by pid so parallel test processes cannot collide.
    static var isolatedSupportDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("autofansmac-tests", isDirectory: true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
}

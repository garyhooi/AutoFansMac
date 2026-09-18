//
//  AppSettings.swift
//  AutoFansMac
//
//  Preference keys and defaults (PROMPT.md §6.6).
//
//  Simple preferences live in UserDefaults and are bound directly with `@AppStorage`
//  in the Settings pane; services read the same keys through this enum so there is one
//  spelling of each key. Profiles (the larger, structured state) are JSON on disk
//  instead — see ProfileStore.
//

import Foundation
import SMCKit

enum SettingsKey {
    // General
    static let showInDock = "showInDock"
    static let temperatureUnit = "temperatureUnit"
    static let pollingInterval = "pollingInterval"
    static let menuBarContent = "menuBarContent"
    static let launchAtLogin = "launchAtLogin"

    // Fan control
    static let restoreFansOnQuit = "restoreFansOnQuit"
    static let allowUnsafeFanTargets = "allowUnsafeFanTargets"
    static let minimumRPMDelta = "minimumRPMDelta"

    // Safety (§6.7.2)
    static let thermalFloorEnabled = "thermalFloorEnabled"
    static let thermalFloorCelsius = "thermalFloorCelsius"
    static let thermalStateOverrideEnabled = "thermalStateOverrideEnabled"

    // Sensors
    static let showUnknownSensors = "showUnknownSensors"
    static let extendedHIDSensors = "extendedHIDSensors"

    // Updates
    static let checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"

    // Helper history
    /// Set the first time the daemon answers this app; cleared by an explicit uninstall.
    /// See `AppSettings.helperHasWorkedBefore`.
    static let helperHasWorkedBefore = "helperHasWorkedBefore"

    // Lifecycle bookkeeping
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    /// Written on launch, cleared on a clean exit: a set flag at startup means the
    /// previous run died with fans possibly pinned (§6.7.5).
    static let runInProgress = "runInProgress"
    static let hiddenMenuBarWarningDismissed = "hiddenMenuBarWarningDismissed"
}

/// What the menu-bar item displays next to/instead of the icon.
enum MenuBarContent: String, CaseIterable, Identifiable {
    case iconOnly
    case fastestFan
    case hottestCPU
    case averageCPU
    case hottestGPU
    case averageGPU
    case selectedSensor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .fastestFan: return "Fastest fan RPM"
        case .hottestCPU: return "CPU hottest"
        case .averageCPU: return "CPU average"
        case .hottestGPU: return "GPU hottest"
        case .averageGPU: return "GPU average"
        case .selectedSensor: return "Selected sensor"
        }
    }

    /// The computed aggregate this option shows, when it shows one.
    ///
    /// The key lives next to the case so the picker and the label cannot drift apart.
    var sensorKey: String? {
        switch self {
        case .hottestCPU: return SensorScanner.ComputedKey.cpuHottest
        case .averageCPU: return SensorScanner.ComputedKey.cpuAverage
        case .hottestGPU: return SensorScanner.ComputedKey.gpuHottest
        case .averageGPU: return SensorScanner.ComputedKey.gpuAverage
        case .iconOnly, .fastestFan, .selectedSensor: return nil
        }
    }

    /// The display group an aggregate is built from.
    ///
    /// Used as the label's fallback for the first tick after launch, when the computed
    /// rows have not been published yet but the plain sensors are already there.
    var sensorGroup: SensorGroup? {
        switch self {
        case .hottestCPU, .averageCPU: return .cpu
        case .hottestGPU, .averageGPU: return .gpu
        case .iconOnly, .fastestFan, .selectedSensor: return nil
        }
    }
}

enum PollingInterval: Double, CaseIterable, Identifiable {
    case half = 0.5
    case one = 1.0
    case two = 2.0
    case five = 5.0

    var id: Double { rawValue }
    var displayName: String {
        rawValue < 1 ? "0.5 s" : "\(Int(rawValue)) s"
    }
}

/// Bounds for the safety thresholds, shared by the UI and the monitor.
enum SafetyBounds {
    static let thermalFloorRange: ClosedRange<Double> = 85...110
    static let defaultThermalFloor: Double = 95
    /// The floor releases once every hot sensor is this far below the threshold.
    static let thermalFloorHysteresis: Double = 10
    /// Never command below this, whatever the profile says (§6.7.1).
    static let absoluteMinimumRPM: Double = 500
    /// Published sensor sanity window.
    static let maximumPlausibleTemperature: Double = 110
}

enum AppSettings {

    /// Registers defaults so `UserDefaults` reads are correct before the Settings pane
    /// has ever been opened.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.showInDock: false,
            SettingsKey.temperatureUnit: TemperatureUnit.celsius.rawValue,
            SettingsKey.pollingInterval: PollingInterval.one.rawValue,
            SettingsKey.menuBarContent: MenuBarContent.hottestCPU.rawValue,
            SettingsKey.launchAtLogin: false,
            SettingsKey.restoreFansOnQuit: true,
            SettingsKey.allowUnsafeFanTargets: false,
            SettingsKey.minimumRPMDelta: 50.0,
            SettingsKey.thermalFloorEnabled: true,
            SettingsKey.thermalFloorCelsius: SafetyBounds.defaultThermalFloor,
            SettingsKey.thermalStateOverrideEnabled: true,
            SettingsKey.showUnknownSensors: true,
            SettingsKey.extendedHIDSensors: false,
            SettingsKey.checkForUpdatesAutomatically: true,
            SettingsKey.helperHasWorkedBefore: false,
            SettingsKey.hasCompletedOnboarding: false,
            SettingsKey.runInProgress: false,
        ])
    }

    static var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: SettingsKey.temperatureUnit) ?? "")
            ?? .celsius
    }

    static var pollingInterval: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.pollingInterval)
        return raw > 0 ? raw : 1.0
    }

    static var minimumRPMDelta: Double {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.minimumRPMDelta)
        return raw > 0 ? raw : 50
    }

    static var thermalFloorCelsius: Double {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.thermalFloorCelsius)
        return SafetyBounds.thermalFloorRange.contains(raw) ? raw : SafetyBounds.defaultThermalFloor
    }

    static var thermalFloorEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.thermalFloorEnabled)
    }

    static var thermalStateOverrideEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.thermalStateOverrideEnabled)
    }

    static var restoreFansOnQuit: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.restoreFansOnQuit)
    }

    static var allowUnsafeFanTargets: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.allowUnsafeFanTargets)
    }

    static var showUnknownSensors: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.showUnknownSensors)
    }

    static var menuBarContent: MenuBarContent {
        MenuBarContent(rawValue: UserDefaults.standard.string(forKey: SettingsKey.menuBarContent) ?? "")
            ?? .hottestCPU
    }

    static var showInDock: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
    }

    /// True once the privileged daemon has answered this app at least once in the past.
    ///
    /// This is the app's only evidence that a *missing* registration is a registration that
    /// was lost — by replacing the app bundle, which invalidates the record — rather than a
    /// helper that was never installed. Registering a root daemon on a machine that never
    /// had one is not something the app may decide by itself, so the distinction matters:
    /// this flag is what makes the difference between repairing and presuming.
    static var helperHasWorkedBefore: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.helperHasWorkedBefore)
    }

    static func markHelperWorked() {
        UserDefaults.standard.set(true, forKey: SettingsKey.helperHasWorkedBefore)
    }

    /// An explicit uninstall must stay uninstalled.
    static func clearHelperHistory() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.helperHasWorkedBefore)
    }

    /// The one setting that permits a network request (see UpdateChecker).
    static var checkForUpdatesAutomatically: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.checkForUpdatesAutomatically)
    }

    // MARK: Dirty-exit bookkeeping

    static func markRunStarted() {
        UserDefaults.standard.set(true, forKey: SettingsKey.runInProgress)
    }

    static func markRunEndedCleanly() {
        UserDefaults.standard.set(false, forKey: SettingsKey.runInProgress)
    }

    /// True when the previous run did not exit cleanly.
    static var previousRunWasUnclean: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.runInProgress)
    }
}

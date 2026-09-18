//
//  SafetyMonitorTests.swift
//  AutoFansMacTests
//
//  PROMPT.md §8/§6.7.2: the thermal floor must engage at the threshold, hold through the
//  hysteresis band, and release only once everything has cooled below floor − 10 °C.
//

import XCTest
import SMCKit
@testable import AutoFansMac

@MainActor
final class SafetyMonitorTests: XCTestCase {

    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        AppSettings.registerDefaults()
        savedDefaults = [
            SettingsKey.thermalFloorEnabled: UserDefaults.standard.bool(forKey: SettingsKey.thermalFloorEnabled),
            SettingsKey.thermalFloorCelsius: UserDefaults.standard.double(forKey: SettingsKey.thermalFloorCelsius),
            SettingsKey.thermalStateOverrideEnabled: UserDefaults.standard.bool(forKey: SettingsKey.thermalStateOverrideEnabled),
        ]
        UserDefaults.standard.set(true, forKey: SettingsKey.thermalFloorEnabled)
        UserDefaults.standard.set(95.0, forKey: SettingsKey.thermalFloorCelsius)
        UserDefaults.standard.set(false, forKey: SettingsKey.thermalStateOverrideEnabled)
    }

    override func tearDown() {
        for (key, value) in savedDefaults {
            UserDefaults.standard.set(value, forKey: key)
        }
        super.tearDown()
    }

    private func sample(key: String, group: SensorGroup, value: Double) -> SensorSample {
        SensorSample(
            key: key, name: key, type: .temperature, group: group, dataType: "flt ",
            rawValue: value, isKnown: true
        )
    }

    func testEngagesAtTheThreshold() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        let decision = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 95.5)])

        guard case .engageMaximum = decision else {
            return XCTFail("expected the thermal floor to engage at 95.5 °C, got \(decision)")
        }
        XCTAssertTrue(monitor.state.isOverriding)
    }

    func testDoesNotEngageBelowTheThreshold() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        let decision = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 94.9)])
        XCTAssertEqual(decision, .none)
        XCTAssertFalse(monitor.state.isOverriding)
    }

    func testHoldsThroughTheHysteresisBand() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        _ = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 96)])

        // 90 °C is above floor − 10 (85), so the override must stay engaged.
        let decision = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 90)])
        XCTAssertEqual(decision, .none)
        XCTAssertTrue(monitor.state.isOverriding, "the override must hold inside the hysteresis band")
    }

    func testReleasesBelowFloorMinusHysteresis() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        _ = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 96)])

        // First drop below the band → move to recovering.
        XCTAssertEqual(monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 84)]), .none)
        // Then the following tick releases and asks for the profile back.
        let decision = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 84)])
        XCTAssertEqual(decision, .releaseOverride)
        XCTAssertFalse(monitor.state.isOverriding)
    }

    func testReengagesIfTemperatureClimbsAgainWhileRecovering() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        _ = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 96)])
        _ = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 84)])

        let decision = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 97)])
        guard case .engageMaximum = decision else {
            return XCTFail("a renewed spike must re-engage the override, got \(decision)")
        }
    }

    func testGPUSensorsAlsoTriggerTheFloor() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        let decision = monitor.evaluate(samples: [sample(key: "Tg0D", group: .gpu, value: 99)])
        guard case .engageMaximum = decision else {
            return XCTFail("GPU sensors must count towards the thermal floor")
        }
    }

    func testUnrelatedGroupsDoNotTriggerTheFloor() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        // A hot battery or ambient sensor is not a CPU/GPU/SOC reading.
        let decision = monitor.evaluate(samples: [
            SensorSample(key: "TB0T", name: "Battery", type: .temperature, group: .system,
                         dataType: "flt ", rawValue: 105, isKnown: true)
        ])
        XCTAssertEqual(decision, .none)
    }

    func testImplausibleReadingsAreIgnored() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        XCTAssertNil(monitor.hottestCriticalTemperature(in: [sample(key: "Tp01", group: .cpu, value: 200)]))
        XCTAssertNil(monitor.hottestCriticalTemperature(in: [sample(key: "Tp01", group: .cpu, value: 0)]))
    }

    func testHottestSensorWins() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        let hottest = monitor.hottestCriticalTemperature(in: [
            sample(key: "Tp01", group: .cpu, value: 55),
            sample(key: "Tg0D", group: .gpu, value: 71),
            sample(key: "Tp05", group: .cpu, value: 63),
        ])
        XCTAssertEqual(hottest?.key, "Tg0D")
        XCTAssertEqual(hottest?.temperature ?? 0, 71, accuracy: 0.001)
    }

    func testResetClearsTheOverride() {
        let monitor = SafetyMonitor(log: DiagnosticsLog())
        _ = monitor.evaluate(samples: [sample(key: "Tp01", group: .cpu, value: 100)])
        XCTAssertTrue(monitor.state.isOverriding)
        monitor.reset()
        XCTAssertFalse(monitor.state.isOverriding)
    }
}

// MARK: - Fan clamping

@MainActor
final class FanClampTests: XCTestCase {

    private func fan(min: Double, max: Double) -> FanDescriptor {
        FanDescriptor(
            index: 0, name: "Test fan", modeKey: "F0Md", targetKey: "F0Tg", actualKey: "F0Ac",
            minKey: "F0Mn", maxKey: "F0Mx", valueType: "flt ", valueSize: 4,
            minRPM: min, maxRPM: max, currentRPM: min, hardwareMode: .auto, warnings: []
        )
    }

    private func service() -> FanService {
        let mock = MockSMC(generation: .appleSiliconDirect)
        return FanService(smc: mock, helper: HelperClient(), log: DiagnosticsLog())
    }

    /// PROMPT.md §6.7.1: the default path must never send 0 RPM, even though the firmware
    /// would happily accept it and stop the fan.
    func testZeroIsClampedUpToTheFanMinimum() {
        let fan = fan(min: 2_317, max: 7_826)
        XCTAssertEqual(service().clamp(rpm: 0, fan: fan), 2_317)
        XCTAssertEqual(service().clamp(rpm: 100, fan: fan), 2_317)
    }

    func testAboveMaximumIsClampedDown() {
        let fan = fan(min: 2_317, max: 7_826)
        XCTAssertEqual(service().clamp(rpm: 12_000, fan: fan), 7_826)
    }

    func testInBandValuesPassThrough() {
        let fan = fan(min: 2_317, max: 7_826)
        XCTAssertEqual(service().clamp(rpm: 4_000, fan: fan), 4_000)
    }

    /// The absolute floor protects machines whose `F%dMn` reads as 0.
    func testAbsoluteFloorProtectsAZeroMinimum() {
        let fan = fan(min: 0, max: 6_000)
        XCTAssertEqual(service().clamp(rpm: 0, fan: fan), SafetyBounds.absoluteMinimumRPM)
    }

    func testExpertOverrideAllowsUnsafeTargets() {
        let fan = fan(min: 2_317, max: 7_826)
        XCTAssertEqual(service().clamp(rpm: 0, fan: fan, allowUnsafe: true), 0)
    }

    func testIsClampedReportsTheWarningState() {
        let fan = fan(min: 2_317, max: 7_826)
        let service = service()
        XCTAssertTrue(service.isClamped(rpm: 100, fan: fan))
        XCTAssertFalse(service.isClamped(rpm: 4_000, fan: fan))
    }

    func testMissingMaximumDegradesToTheMinimum() {
        let fan = fan(min: 3_000, max: 0)
        XCTAssertEqual(service().clamp(rpm: 5_000, fan: fan), 3_000)
    }
}

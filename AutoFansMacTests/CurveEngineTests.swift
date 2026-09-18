//
//  CurveEngineTests.swift
//  AutoFansMacTests
//
//  PROMPT.md §8 unit tests for the curve engine: the ramp table, EMA convergence,
//  hysteresis (no write for Δ<50), the sensor-lost fail-safe and clamp interaction.
//

import XCTest
import SMCKit
@testable import AutoFansMac

final class CurveMathTests: XCTestCase {

    private let minTemp = 50.0
    private let maxTemp = 80.0
    private let lo = 1_200.0
    private let hi = 6_000.0

    private func ramp(_ temperature: Double) -> Double {
        CurveMath.targetRPM(
            temperature: temperature,
            minTemp: minTemp,
            maxTemp: maxTemp,
            startRPM: lo,
            capRPM: hi
        )
    }

    // MARK: Ramp table

    func testBelowTminHoldsStartRPM() {
        XCTAssertEqual(ramp(20), lo)
        XCTAssertEqual(ramp(49.9), lo)
    }

    func testAtTminIsExactlyStartRPM() {
        XCTAssertEqual(ramp(50), lo)
    }

    func testAtTmaxIsExactlyCapRPM() {
        XCTAssertEqual(ramp(80), hi)
    }

    func testAboveTmaxSaturatesAtCapRPM() {
        XCTAssertEqual(ramp(95), hi)
        XCTAssertEqual(ramp(200), hi)
    }

    func testMidpointIsHalfway() {
        // 65 °C is exactly halfway between Tmin 50 and Tmax 80.
        XCTAssertEqual(ramp(65), lo + (hi - lo) / 2, accuracy: 0.001)
    }

    func testQuarterPoint() {
        // 57.5 °C is a quarter of the way up.
        XCTAssertEqual(ramp(57.5), lo + (hi - lo) * 0.25, accuracy: 0.001)
    }

    func testMonotonicAcrossRange() {
        var previous = -Double.infinity
        for step in 0...60 {
            let temperature = 40 + Double(step) * 0.5
            let value = ramp(temperature)
            XCTAssertGreaterThanOrEqual(value, previous, "the curve must never decrease as temperature rises")
            previous = value
        }
    }

    func testSymmetricRampWalksBackDown() {
        let rising = ramp(70)
        let falling = ramp(70)
        XCTAssertEqual(rising, falling, "the ramp must be identical in both directions")
    }

    func testDegenerateRangeDoesNotDivideByZero() {
        let value = CurveMath.targetRPM(temperature: 60, minTemp: 60, maxTemp: 60, startRPM: lo, capRPM: hi)
        XCTAssertTrue(value.isFinite)
        XCTAssertEqual(value, hi, "Tmax == Tmin at or above the threshold means full speed")
    }

    func testInvertedCapFallsBackToStart() {
        let value = CurveMath.targetRPM(temperature: 70, minTemp: 50, maxTemp: 80, startRPM: 5_000, capRPM: 1_000)
        XCTAssertEqual(value, 5_000, "a cap below the start RPM is not a usable ramp")
    }

    // MARK: EMA

    func testEMAConvergesTowardsTheSample() {
        var smoothed: Double? = nil
        for _ in 0..<20 {
            smoothed = CurveMath.ema(previous: smoothed, sample: 90)
        }
        XCTAssertEqual(smoothed ?? 0, 90, accuracy: 0.5, "EMA must converge on a constant input")
    }

    func testEMASmoothsASpike() {
        // A single spike must not move the smoothed value all the way.
        let smoothed = CurveMath.ema(previous: 40, sample: 100)
        XCTAssertEqual(smoothed, 0.3 * 100 + 0.7 * 40, accuracy: 0.001)
        XCTAssertLessThan(smoothed, 60, "one spike must not dominate the average")
    }

    func testEMASeedsOnFirstSample() {
        XCTAssertEqual(CurveMath.ema(previous: nil, sample: 61.5), 61.5)
    }

    // MARK: Full evaluation

    private func fan(min: Double = 1_000, max: Double = 7_000) -> FanDescriptor {
        FanDescriptor(
            index: 0, name: "Test fan", modeKey: "F0Md", targetKey: "F0Tg", actualKey: "F0Ac",
            minKey: "F0Mn", maxKey: "F0Mx", valueType: "flt ", valueSize: 4,
            minRPM: min, maxRPM: max, currentRPM: min, hardwareMode: .manual, warnings: []
        )
    }

    private func setting(minTemp: Double = 50, maxTemp: Double = 80, start: Double? = nil, cap: Double? = nil) -> FanSetting {
        FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: "CPU proximity",
            minTemp: minTemp, maxTemp: maxTemp, startRPM: start, capRPM: cap
        )
    }

    func testEvaluationDefaultsToTheFanRange() {
        let evaluation = CurveMath.evaluate(
            setting: setting(), fan: fan(), temperature: 30, previousSmoothed: nil, sensorLost: false
        )
        XCTAssertEqual(evaluation.startRPM, 1_000, "default start RPM is F%dMn")
        XCTAssertEqual(evaluation.capRPM, 7_000, "default cap RPM is F%dMx")
        XCTAssertEqual(evaluation.targetRPM, 1_000)
    }

    func testEvaluationHonoursAdvancedOverrides() {
        let evaluation = CurveMath.evaluate(
            setting: setting(start: 2_000, cap: 5_000), fan: fan(), temperature: 95,
            previousSmoothed: nil, sensorLost: false
        )
        XCTAssertEqual(evaluation.targetRPM, 5_000)
    }

    func testLostSensorRaisesTheFanToCap() {
        let evaluation = CurveMath.evaluate(
            setting: setting(), fan: fan(), temperature: nil, previousSmoothed: 55, sensorLost: true
        )
        XCTAssertTrue(evaluation.sensorLost)
        XCTAssertEqual(evaluation.targetRPM, 7_000, "a lost sensor must fail safe to maximum, not to minimum")
    }
}

// MARK: - Engine behaviour

final class CurveEngineTests: XCTestCase {

    private func fan() -> FanDescriptor {
        FanDescriptor(
            index: 0, name: "Test fan", modeKey: "F0Md", targetKey: "F0Tg", actualKey: "F0Ac",
            minKey: "F0Mn", maxKey: "F0Mx", valueType: "flt ", valueSize: 4,
            minRPM: 1_000, maxRPM: 6_000, currentRPM: 1_000, hardwareMode: .manual, warnings: []
        )
    }

    func testHysteresisSuppressesSmallChanges() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        // A deliberately shallow ramp: 1000 RPM spread over a 70 °C range is ~14 RPM per
        // degree, so the 50 RPM minimum delta must swallow most of these steps.
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 30, maxTemp: 100, startRPM: 2_000, capRPM: 3_000
        )
        var writes: [Double] = []
        let writer: (Int, Double) async -> Bool = { _, rpm in
            writes.append(rpm)
            return true
        }

        var temperature = 60.0
        let ticks = 10
        for _ in 0..<ticks {
            _ = await engine.tick(
                settings: [setting],
                fans: [fan()],
                temperatureProvider: { _ in temperature },
                writer: writer
            )
            temperature += 1
        }

        XCTAssertGreaterThanOrEqual(writes.count, 1, "the first evaluation must always be written")
        XCTAssertLessThan(
            writes.count, ticks,
            "the 50 RPM minimum delta must suppress steps on a shallow ramp (got \(writes.count) of \(ticks))"
        )
    }

    func testSteepRampWritesAlmostEveryTick() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        // 6000 RPM over a 12 °C range is 500 RPM per degree — every tick is material.
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 30, maxTemp: 42, startRPM: 1_000, capRPM: 7_000
        )
        var writes: [Double] = []
        let writer: (Int, Double) async -> Bool = { _, rpm in writes.append(rpm); return true }

        var temperature = 31.0
        let ticks = 8
        for _ in 0..<ticks {
            _ = await engine.tick(
                settings: [setting],
                fans: [fan()],
                temperatureProvider: { _ in temperature },
                writer: writer
            )
            temperature += 1
        }

        XCTAssertGreaterThanOrEqual(
            writes.count, ticks - 2,
            "a steep ramp must keep writing as the target moves (got \(writes.count) of \(ticks))"
        )
        // And the commanded values must rise with temperature.
        XCTAssertEqual(writes, writes.sorted())
    }

    func testTrackedSensorChangeReseedsEMA() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        var setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80, startRPM: 1_000, capRPM: 6_000
        )
        var writes: [Double] = []
        let writer: (Int, Double) async -> Bool = { _, rpm in writes.append(rpm); return true }

        _ = await engine.tick(settings: [setting], fans: [fan()], temperatureProvider: { _ in 90 }, writer: writer)
        let first = engine.smoothedTemperature(fanIndex: 0)
        XCTAssertEqual(first ?? 0, 90, accuracy: 0.001, "the first sample seeds the EMA directly")

        setting.sensorKey = "Tp01"
        _ = await engine.tick(settings: [setting], fans: [fan()], temperatureProvider: { _ in 40 }, writer: writer)
        XCTAssertEqual(
            engine.smoothedTemperature(fanIndex: 0) ?? 0, 40, accuracy: 0.001,
            "changing the tracked sensor must re-seed the EMA instead of ramping from the old value"
        )
    }

    func testMissingTemperatureIsTreatedAsLostAfterNoSample() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80
        )
        var writes: [Double] = []
        let writer: (Int, Double) async -> Bool = { _, rpm in writes.append(rpm); return true }

        // No sample has ever been seen → the curve is already in the lost state.
        _ = await engine.tick(settings: [setting], fans: [fan()], temperatureProvider: { _ in nil }, writer: writer)
        XCTAssertEqual(writes.first, 6_000, "a curve with no sensor reading must fail safe to maximum")
        XCTAssertTrue(engine.isSensorLost(fanIndex: 0))
    }

    /// The circuit breaker behind "switching sensor keeps jumping": re-applying an identical
    /// curve must be a no-op, or a redraw that looks like a selection change drives an endless
    /// command→publish→redraw loop (observed at ~30 Hz, one XPC round trip each).
    func testIdenticalCurveIsNotMaterial() {
        var setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "Tp01", sensorName: "CPU core",
            minTemp: 50, maxTemp: 80
        )
        XCTAssertFalse(setting.differsFromCurve(sensorKey: "Tp01", minTemp: 50, maxTemp: 80),
                       "the same sensor and temperatures must not re-command the fan")

        XCTAssertTrue(setting.differsFromCurve(sensorKey: "Tg0D", minTemp: 50, maxTemp: 80),
                      "a different sensor is a real change")
        XCTAssertTrue(setting.differsFromCurve(sensorKey: "Tp01", minTemp: 55, maxTemp: 80),
                      "a different Tmin is a real change")
        XCTAssertTrue(setting.differsFromCurve(sensorKey: "Tp01", minTemp: 50, maxTemp: 85),
                      "a different Tmax is a real change")

        // A fan that is not in sensor mode yet always needs the command.
        setting.mode = .constant
        XCTAssertTrue(setting.differsFromCurve(sensorKey: "Tp01", minTemp: 50, maxTemp: 80))
    }

    // MARK: Below Tmin the fan is handed back to macOS

    /// "After I change to sensor-based, the fans start immediately even though the temperature
    /// is lower than Tmin." Pinning the fan at `F%dMn` (2317) below Tmin is both what the user
    /// noticed and pointless: macOS idles these fans at 0 RPM when it owns them.
    func testFanIsReleasedBelowTminAndNotCommanded() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80
        )
        var writes: [Double] = []
        var releases: [Int] = []

        _ = await engine.tick(
            settings: [setting], fans: [fan()],
            temperatureProvider: { _ in 40 },
            writer: { _, rpm in writes.append(rpm); return true },
            releaser: { index in releases.append(index); return true }
        )

        XCTAssertTrue(writes.isEmpty, "a cold machine must not be commanded at all")
        XCTAssertTrue(releases.isEmpty, "nothing to release: the fan was never taken")
        XCTAssertFalse(engine.isEngaged(fanIndex: 0))
    }

    func testFanIsTakenOverOnceTheSensorReachesTmin() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80
        )
        var writes: [Double] = []

        _ = await engine.tick(
            settings: [setting], fans: [fan()],
            temperatureProvider: { _ in 55 },
            writer: { _, rpm in writes.append(rpm); return true }
        )

        XCTAssertEqual(writes.count, 1)
        // 55 °C on a 50–80 ramp from F%dMn (1000) to F%dMx (6000) is one sixth of the way up.
        XCTAssertEqual(writes.first ?? 0, 1_000 + (6_000 - 1_000) / 6, accuracy: 1)
        XCTAssertTrue(engine.isEngaged(fanIndex: 0))
    }

    func testHysteresisStopsTheFanFlappingAtTheThreshold() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80
        )
        var releases: [Int] = []
        let releaser: (Int) async -> Bool = { index in releases.append(index); return true }

        // The engine decides on the *smoothed* temperature (EMA α = 0.3), so each plateau needs
        // a few ticks to settle before its value means anything.
        func settle(at temperature: Double, ticks: Int = 20) async {
            for _ in 0..<ticks {
                _ = await engine.tick(settings: [setting], fans: [fan()],
                                      temperatureProvider: { _ in temperature },
                                      writer: { _, _ in true }, releaser: releaser)
            }
        }

        await settle(at: 55, ticks: 1)                 // take the fan
        XCTAssertTrue(engine.isEngaged(fanIndex: 0))

        // 48 °C is inside the 3 °C band below Tmin: stay engaged rather than flapping.
        await settle(at: 48)
        XCTAssertTrue(releases.isEmpty, "inside the hysteresis band the fan stays ours")

        // 45 °C is below Tmin − 3: hand it back, once.
        await settle(at: 45)
        XCTAssertEqual(releases, [0])
        XCTAssertFalse(engine.isEngaged(fanIndex: 0), "and it must not be released twice per crossing")

        // Staying cold must not release again.
        await settle(at: 45)
        XCTAssertEqual(releases, [0])
    }

    /// An explicit `startRPM` is the documented "hold this floor" setting, so it opts out of
    /// the release behaviour and keeps the fan pinned there.
    func testExplicitStartRPMKeepsTheFanHeldBelowTmin() async {
        let engine = CurveEngine(log: DiagnosticsLog())
        let setting = FanSetting(
            index: 0, mode: .sensor, rpm: .value(0), sensorKey: "TC0P", sensorName: nil,
            minTemp: 50, maxTemp: 80, startRPM: 2_500, capRPM: 6_000
        )
        var writes: [Double] = []
        var releases: [Int] = []

        _ = await engine.tick(
            settings: [setting], fans: [fan()],
            temperatureProvider: { _ in 30 },
            writer: { _, rpm in writes.append(rpm); return true },
            releaser: { index in releases.append(index); return true }
        )

        XCTAssertEqual(writes, [2_500])
        XCTAssertTrue(releases.isEmpty)
    }

    func testTrackedSensorKeysOnlyIncludesSensorFans() {
        let engine = CurveEngine(log: DiagnosticsLog())
        let settings = [
            FanSetting.auto(0),
            FanSetting(index: 1, mode: .constant, rpm: .value(2_000)),
            FanSetting(index: 2, mode: .sensor, rpm: .value(0), sensorKey: "Tp01", minTemp: 50, maxTemp: 80),
        ]
        XCTAssertEqual(engine.trackedSensorKeys(settings: settings), ["Tp01"])
    }
}

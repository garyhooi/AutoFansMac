//
//  SensorScannerTests.swift
//  SMCKitTests
//
//  Discovery, classification, sanity filtering and the computed aggregates the curve engine
//  and the menu bar track (PROMPT.md §4.7).
//

import XCTest
@testable import SMCKit

final class SensorScannerTests: XCTestCase {

    private func platform(_ generation: ChipGeneration = .m5) -> PlatformInfo {
        PlatformInfo(
            modelIdentifier: "Test1,1",
            architecture: "arm64",
            chipName: generation.rawValue,
            generation: generation,
            macOSVersion: "27.0",
            macOSBuild: "TEST",
            isAppleSilicon: true,
            logicalCPUCount: 8,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024
        )
    }

    // MARK: Classification

    func testKeysAreClassifiedByFirstCharacter() {
        XCTAssertEqual(SensorScanner.classify("TC0P"), .temperature)
        XCTAssertEqual(SensorScanner.classify("VP0R"), .voltage)
        XCTAssertEqual(SensorScanner.classify("PSTR"), .power)
        XCTAssertEqual(SensorScanner.classify("ID0R"), .current)
        // Fan keys are read by FanHardware, not the sensor sweep.
        XCTAssertNil(SensorScanner.classify("F0Ac"))
        XCTAssertNil(SensorScanner.classify("#KEY"))
        XCTAssertNil(SensorScanner.classify("TOO_LONG"))
    }

    func testPlausibilityWindows() {
        XCTAssertTrue(SensorScanner.isPlausible(45, type: .temperature))
        XCTAssertFalse(SensorScanner.isPlausible(0, type: .temperature), "0 °C is a dead sensor")
        XCTAssertFalse(SensorScanner.isPlausible(120, type: .temperature))
        XCTAssertFalse(SensorScanner.isPlausible(150, type: .current))
        XCTAssertTrue(SensorScanner.isPlausible(12, type: .voltage))
    }

    // MARK: Computed aggregates

    private func sample(_ key: String, _ group: SensorGroup, _ value: Double) -> SensorSample {
        SensorSample(key: key, name: key, type: .temperature, group: group, dataType: "flt ",
                     rawValue: value, isKnown: true)
    }

    func testComputedAggregatesCoverCpuAndGpu() throws {
        let computed = SensorScanner.computedSensors(from: [
            sample("Tp01", .cpu, 60),
            sample("Tp05", .cpu, 70),
            sample("Tg0D", .gpu, 50),
            sample("Tg0L", .gpu, 62),
        ])
        let byKey = Dictionary(uniqueKeysWithValues: computed.map { ($0.key, $0) })

        XCTAssertEqual(byKey[SensorScanner.ComputedKey.cpuAverage]?.rawValue, 65)
        XCTAssertEqual(byKey[SensorScanner.ComputedKey.cpuHottest]?.rawValue, 70)

        // GPU average tracks the mean of the GPU cluster sensors; GPU hottest the peak.
        XCTAssertEqual(try XCTUnwrap(byKey[SensorScanner.ComputedKey.gpuAverage]).rawValue, 56, accuracy: 0.001)
        XCTAssertEqual(byKey[SensorScanner.ComputedKey.gpuHottest]?.rawValue, 62)
        XCTAssertEqual(byKey[SensorScanner.ComputedKey.gpuAverage]?.name, "GPU average")
        XCTAssertTrue(byKey[SensorScanner.ComputedKey.gpuAverage]?.isComputed ?? false)
    }

    func testGpuAggregatesAreAbsentWhenTheMachineReportsNoGpuSensors() {
        let computed = SensorScanner.computedSensors(from: [sample("Tp01", .cpu, 60)])
        let keys = Set(computed.map(\.key))
        XCTAssertFalse(keys.contains(SensorScanner.ComputedKey.gpuAverage))
        XCTAssertFalse(keys.contains(SensorScanner.ComputedKey.gpuHottest))
        XCTAssertTrue(keys.contains(SensorScanner.ComputedKey.cpuAverage))
    }

    func testComputedAggregatesIgnoreOtherComputedSamples() throws {
        // Feeding computed samples back in must not skew the averages for ever.
        let once = SensorScanner.computedSensors(from: [sample("Tg0D", .gpu, 50), sample("Tg0L", .gpu, 60)])
        let twice = SensorScanner.computedSensors(from: [
            sample("Tg0D", .gpu, 50), sample("Tg0L", .gpu, 60),
        ] + once)
        let average = twice.first { $0.key == SensorScanner.ComputedKey.gpuAverage }
        XCTAssertEqual(try XCTUnwrap(average).rawValue, 55, accuracy: 0.001)
    }

    /// The catalog lags new silicon. On an M5 Pro it names 9 of ~44 `Tg*` GPU cluster sensors;
    /// the rest are "unknown" keys and used to be excluded from the aggregates *and* from the
    /// thermal floor — which is a safety gap, not just a cosmetic one.
    func testUnknownSensorsStillCountTowardsTheirFamily() {
        let unknownGpu = SensorSample(
            key: "Tg3B", name: "Tg3B", type: .temperature, group: .unknown,
            dataType: "flt ", rawValue: 78.5, isKnown: false
        )
        let namedGpu = sample("Tg0D", .gpu, 50)
        let unknownCpu = SensorSample(
            key: "Tp0y", name: "Tp0y", type: .temperature, group: .unknown,
            dataType: "flt ", rawValue: 70, isKnown: false
        )

        XCTAssertEqual(unknownGpu.criticalGroup, .gpu)
        XCTAssertEqual(unknownCpu.criticalGroup, .cpu)

        let computed = SensorScanner.computedSensors(from: [unknownGpu, namedGpu, unknownCpu])
        let byKey = Dictionary(uniqueKeysWithValues: computed.map { ($0.key, $0.rawValue) })
        XCTAssertEqual(byKey[SensorScanner.ComputedKey.gpuHottest], 78.5,
                       "an unnamed GPU sensor must be able to be the hottest")
        XCTAssertEqual(byKey[SensorScanner.ComputedKey.cpuHottest], 70)
    }

    func testFamilyAttributionStaysConservative() {
        // Families that do not unambiguously mean CPU or GPU must not be claimed.
        let ambiguous = SensorSample(
            key: "TV11", name: "TV11", type: .temperature, group: .unknown,
            dataType: "flt ", rawValue: 34, isKnown: false
        )
        XCTAssertEqual(ambiguous.criticalGroup, .unknown)

        // Only temperatures: a voltage key shaped like a CPU one is not a CPU sensor.
        let voltage = SensorSample(
            key: "Tp9z", name: "Tp9z", type: .voltage, group: .unknown,
            dataType: "sp78", rawValue: 1.2, isKnown: false
        )
        XCTAssertEqual(voltage.criticalGroup, .unknown)

        // A catalogued group always wins.
        XCTAssertEqual(sample("TB0T", .system, 30).criticalGroup, .system)
    }

    func testFastestFanAggregate() {
        let fans = [
            SensorSample(key: "F0Ac", name: "Left", type: .fan, group: .sensor, dataType: "flt ",
                         rawValue: 2_000, isKnown: true, isFan: true, fanIndex: 0),
            SensorSample(key: "F1Ac", name: "Right", type: .fan, group: .sensor, dataType: "flt ",
                         rawValue: 3_400, isKnown: true, isFan: true, fanIndex: 1),
        ]
        let computed = SensorScanner.computedSensors(from: fans)
        let fastest = computed.first { $0.key == SensorScanner.ComputedKey.fastestFan }
        XCTAssertEqual(fastest?.rawValue, 3_400)
    }

    // MARK: Full and partial sweeps

    func testScanClassifiesNamesAndGroups() {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let result = SensorScanner.scan(mock, platform: platform())

        XCTAssertFalse(result.samples.isEmpty)
        let cpu = result.temperatureSamples.first { $0.group == .cpu && !$0.isComputed }
        XCTAssertNotNil(cpu, "the CPU group must be populated")
        XCTAssertTrue(result.samples.allSatisfy { $0.type != .energy })
    }

    /// The Sensors window passes an explicit key list; the background poller passes a hot
    /// subset. A partial sweep must read exactly those keys.
    func testScanHonoursAnExplicitKeyList() {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let result = SensorScanner.scan(mock, platform: platform(), keys: ["TC0P"])

        let nonComputed = result.samples.filter { !$0.isComputed && $0.type != .fan }
        XCTAssertEqual(nonComputed.map(\.key), ["TC0P"])
        XCTAssertEqual(result.scannedKeyCount, 1)
    }

    func testAllZeroReadsAreTreatedAsAbsent() {
        let mock = MockSMC(generation: .appleSiliconDirect)
        mock.seed("TZZZ", dataType: "sp78", byteCount: 2, bytes: [0x00, 0x00])

        let result = SensorScanner.scan(mock, platform: platform(), keys: ["TZZZ"])
        XCTAssertTrue(result.samples.filter { !$0.isComputed }.isEmpty,
                      "an all-zero sensor read means the sensor is absent on this model")
        XCTAssertTrue(result.absentKeys.contains("TZZZ"))
    }
}

//
//  UnlockSequencerTests.swift
//  SMCKitTests
//
//  The five generation scenarios from PROMPT.md §8, driven entirely by MockSMC +
//  a virtual clock so they are deterministic and instant.
//

import XCTest
@testable import SMCKit

final class UnlockSequencerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSequencer(
        _ mock: MockSMC,
        generation: ChipGeneration,
        hasFtst: Bool,
        hasForceMask: Bool,
        unlockStyle: UnlockStyle,
        parameters: UnlockParameters = UnlockParameters()
    ) -> (UnlockSequencer, FanHardwareSnapshot) {
        let snapshot = FanHardware.probe(mock, platform: Self.platform(generation))
        XCTAssertEqual(snapshot.hasFtst, hasFtst, "Ftst presence probe")
        XCTAssertEqual(snapshot.hasForceMask, hasForceMask, "FS! presence probe")
        XCTAssertEqual(snapshot.unlockStyle, unlockStyle, "unlock style hint")
        let sequencer = UnlockSequencer(
            access: mock,
            snapshot: snapshot,
            clock: mock.clock,
            parameters: parameters
        )
        return (sequencer, snapshot)
    }

    static func platform(_ generation: ChipGeneration) -> PlatformInfo {
        PlatformInfo(
            modelIdentifier: "Test1,1",
            architecture: generation.isAppleSilicon ? "arm64" : "x86_64",
            chipName: generation.rawValue,
            generation: generation,
            macOSVersion: "27.0",
            macOSBuild: "TEST",
            isAppleSilicon: generation.isAppleSilicon,
            logicalCPUCount: 8,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024
        )
    }

    // MARK: - Scenario 1: M1 — direct write, no unlock

    func testM1DirectManualMode() throws {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )

        let fan = try XCTUnwrap(snapshot.fans.first)
        XCTAssertEqual(fan.modeKey, "F0Md")
        XCTAssertEqual(fan.valueType, "flt ", "Apple Silicon fan values are flt")

        let result = sequencer.ensureManualMode(fan)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(mock.mode(fan: 0), 1)
        XCTAssertEqual(mock.writes(forKey: "F0Md").count, 1, "no retries needed for a direct write")

        // The fan must physically follow the commanded target.
        let outcome = try sequencer.setTarget(fan: fan, rpm: 3_000).get()
        XCTAssertTrue(outcome.applied)
        XCTAssertTrue(outcome.verified)
        XCTAssertFalse(outcome.unresponsive)
        XCTAssertEqual(mock.actualRPM(fan: 0), 3_000, accuracy: 1)
    }

    // MARK: - Scenario 2: M3/M4 — 0x82, Ftst unlock, daemon yields

    func testM3LockedRequiresFtstUnlock() throws {
        let mock = MockSMC(generation: .appleSiliconLocked)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        // The daemon holds mode 3 and the firmware answers 0x82 to a direct write.
        XCTAssertEqual(mock.mode(fan: 0), 3)
        XCTAssertEqual(mock.readInt(fan.modeKey), 3)

        let result = sequencer.ensureManualMode(fan)
        XCTAssertNoThrow(try result.get(), "the Ftst unlock path must succeed")

        XCTAssertTrue(mock.isFtstSet(), "Ftst must be held while a fan is manual")
        XCTAssertEqual(mock.mode(fan: 0), 1)
        XCTAssertTrue(sequencer.isFtstHeld)
        XCTAssertTrue(sequencer.manualFans.contains(0))

        // The first mode write was rejected with 0x82 before the unlock.
        let modeWrites = mock.writes(forKey: "F0Md")
        XCTAssertGreaterThan(modeWrites.count, 1)
        XCTAssertEqual(modeWrites.first?.result, .smcResult(SMCSMCResult.badCommand.rawValue))

        // Mode reads 0 after the daemon yields (the 3 s virtual sleep happened).
        XCTAssertGreaterThanOrEqual((mock.clock as? VirtualSMCClock)?.totalSleepMilliseconds ?? 0, 3_000)
    }

    func testM3SecondFanReusesTheHeldUnlock() throws {
        let mock = MockSMC(generation: .appleSiliconLocked)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock
        )
        let fan0 = snapshot.fans[0]
        let fan1 = snapshot.fans[1]

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan0).get())
        let ftstWritesAfterFan0 = mock.writes(forKey: "Ftst").count
        XCTAssertEqual(ftstWritesAfterFan0, 1)

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan1).get())
        XCTAssertEqual(mock.writes(forKey: "Ftst").count, ftstWritesAfterFan0, "Ftst is set once, not per fan")
        XCTAssertEqual(mock.mode(fan: 1), 1)
    }

    // MARK: - Scenario 3: M5 — lowercase key, no Ftst, direct write works

    func testM5LowercaseModeKeyWithoutFtst() throws {
        let mock = MockSMC(generation: .appleSiliconLowercase)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m5, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )

        XCTAssertTrue(snapshot.modeKeyIsLowercase, "F0Md must be absent and F0md present")
        let fan = try XCTUnwrap(snapshot.fans.first)
        XCTAssertEqual(fan.modeKey, "F0md")
        XCTAssertFalse(mock.exists("F0Md"))
        XCTAssertFalse(mock.exists("Ftst"))

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan).get())
        XCTAssertEqual(mock.mode(fan: 0), 1)
        XCTAssertTrue(mock.writes(forKey: "F0md").count >= 1)
        XCTAssertEqual(mock.writes(forKey: "Ftst").count, 0, "no Ftst writes on a machine without the key")
    }

    // MARK: - Scenario 4: Intel — FS! bitmask transitions

    func testIntelForceMaskTransitions() throws {
        let mock = MockSMC(generation: .intel)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .intel, hasFtst: false, hasForceMask: true, unlockStyle: .intelForceMask
        )
        let fan0 = snapshot.fans[0]
        let fan1 = snapshot.fans[1]
        XCTAssertEqual(fan0.valueType, "fpe2", "legacy Intel fan values are fpe2")

        func forceMask() -> Int { mock.readInt("FS! ") ?? -1 }

        XCTAssertEqual(forceMask(), 0)

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan0).get())
        XCTAssertEqual(forceMask(), 0b01)

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan1).get())
        XCTAssertEqual(forceMask(), 0b11)

        XCTAssertNoThrow(try sequencer.releaseAuto(fan: fan0, isLastManualFan: false).get())
        XCTAssertEqual(forceMask(), 0b10)

        XCTAssertNoThrow(try sequencer.releaseAuto(fan: fan1, isLastManualFan: true).get())
        XCTAssertEqual(forceMask(), 0b00)
    }

    func testIntelTargetIsEncodedAsFpe2() throws {
        let mock = MockSMC(generation: .intel)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .intel, hasFtst: false, hasForceMask: true, unlockStyle: .intelForceMask
        )
        let fan = snapshot.fans[0]
        XCTAssertNoThrow(try sequencer.setTarget(fan: fan, rpm: 2_000).get())

        let write = try XCTUnwrap(mock.writes(forKey: "F0Tg").last)
        XCTAssertEqual(write.bytes.count >= 2, true)
        // fpe2 = unsigned 14.2 big-endian: b0 = (rpm >> 6) & 0xFF, b1 = (rpm << 2) & 0xFF.
        // 2000 RPM (0x07D0) → b0 = 0x1F, b1 = 0x40.
        XCTAssertEqual(write.bytes[0], 0x1F)
        XCTAssertEqual(write.bytes[1], 0x40)
        // And it decodes back to 2000 exactly.
        XCTAssertEqual(
            try SMCCodecs.decode(dataType: "fpe2", bytes: write.bytes, byteCount: 2).doubleValue,
            2_000
        )
    }

    // MARK: - Scenario 5: firmware refuses and no unlock key exists

    /// A fan at a standstill takes longer to start than a spinning one takes to change speed.
    /// With one fixed window this healthy spin-up was reported as "The fan did not move after a
    /// 2317 RPM command" — exactly what a MacBook Pro M5 Pro produced, whose fans idle at 0 RPM.
    func testFanStartingFromRestIsNotCalledUnresponsive() throws {
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.fanSpoolRPMPerSecond = 1_500
        options.fanStartupDelaySeconds = 4        // longer than the normal 3 s window
        let mock = MockSMC(options: options)
        mock.setFanSpeed(fan: 0, actual: 0, target: 0)

        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let outcome = try sequencer.setTarget(fan: fan, rpm: 2_317).get()
        XCTAssertEqual(outcome.response, .converging,
                       "a fan that is still breaking free is responding, not broken")
        XCTAssertFalse(outcome.unresponsive)
    }

    /// The patience is bounded: a fan that never starts is still reported honestly.
    func testFanThatNeverStartsIsStillStalled() throws {
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.fanResponds = false
        let mock = MockSMC(options: options)
        mock.setFanSpeed(fan: 0, actual: 0, target: 0)

        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let outcome = try sequencer.setTarget(fan: fan, rpm: 2_317).get()
        XCTAssertEqual(outcome.response, .stalled)
        XCTAssertTrue(outcome.unresponsive)

        // And it must have used the longer window rather than giving up after 3 s.
        let clock = try XCTUnwrap(mock.clock as? VirtualSMCClock)
        XCTAssertGreaterThanOrEqual(clock.totalSleepMilliseconds, 6_000,
                                    "a fan at rest gets the spin-up window before being judged")
    }

    /// A fan already turning keeps the shorter, snappier window.
    func testSpinningFanUsesTheNormalWindow() throws {
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.fanResponds = false
        let mock = MockSMC(options: options)
        mock.setFanSpeed(fan: 0, actual: 3_000, target: 3_000)

        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        _ = try sequencer.setTarget(fan: fan, rpm: 3_500).get()
        let clock = try XCTUnwrap(mock.clock as? VirtualSMCClock)
        XCTAssertLessThan(clock.totalSleepMilliseconds, 6_000)
    }

    func testLockedMachineWithoutFtstFailsHonestly() throws {
        let mock = MockSMC(generation: .appleSiliconLockedNoFtst)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: false, hasForceMask: false, unlockStyle: .unavailable
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let result = sequencer.ensureManualMode(fan)
        guard case .failure(let failure) = result else {
            return XCTFail("expected an honest failure when the firmware refuses and Ftst is absent")
        }
        XCTAssertEqual(failure, .firmwareRefusedManualMode(smcCode: SMCSMCResult.badCommand.rawValue))
        XCTAssertEqual(failure.shortReason, "Custom mode unavailable (firmware refused)")
        XCTAssertEqual(mock.writes(forKey: "Ftst").count, 0)
        XCTAssertEqual(mock.mode(fan: 0), 3, "the fan stays under system control")
    }

    func testFtstWriteFailureIsReported() throws {
        let mock = MockSMC(generation: .appleSiliconLocked)
        mock.writeRules = [MockSMC.WriteRule(key: "Ftst", result: .smcResult(SMCSMCResult.notWritable.rawValue), times: 1_000)]
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let result = sequencer.ensureManualMode(fan)
        guard case .failure(let failure) = result else { return XCTFail("expected the Ftst write to fail") }
        XCTAssertEqual(failure, .ftstWriteFailed(smcCode: SMCSMCResult.notWritable.rawValue))
        XCTAssertFalse(sequencer.isFtstHeld)
    }

    func testUnlockTimeoutIsBounded() throws {
        // The daemon never yields: Ftst is accepted but the mode key keeps answering 0x82.
        let mock = MockSMC(generation: .appleSiliconLocked)
        var options = UnlockParameters()
        options.yieldTimeoutMilliseconds = 5_000
        options.modeWriteAttempts = 1          // isolate the yield-wait budget
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock,
            parameters: options
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        // Make the yield never happen by scripting every mode write after the unlock.
        mock.writeRules = [MockSMC.WriteRule(key: "F0Md", result: .smcResult(SMCSMCResult.badCommand.rawValue), times: 1_000)]

        let result = sequencer.ensureManualMode(fan)
        guard case .failure(let failure) = result else { return XCTFail("expected a timeout") }
        XCTAssertEqual(failure, .unlockTimedOut)

        let clock = try XCTUnwrap(mock.clock as? VirtualSMCClock)
        XCTAssertGreaterThanOrEqual(clock.totalSleepMilliseconds, options.yieldTimeoutMilliseconds)
        XCTAssertLessThanOrEqual(
            clock.totalSleepMilliseconds,
            options.yieldTimeoutMilliseconds + options.yieldPollIntervalMilliseconds + 50,
            "the wait must be bounded by the yield timeout"
        )
    }

    // MARK: - Permission and target edge cases

    func testPermissionDeniedIsClassified() throws {
        let mock = MockSMC(generation: .appleSiliconDirect)
        mock.iokitErrorForWrites = kIOReturnNotPrivileged
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let result = sequencer.ensureManualMode(fan)
        guard case .failure(let failure) = result else { return XCTFail("expected permissionDenied") }
        XCTAssertEqual(failure, .permissionDenied)
        XCTAssertEqual(failure.shortReason, "Helper required")
    }

    func testTargetWriteWhileNotManualIsRejectedByFirmware() throws {
        // Pitfall #6: never write F%dTg on Apple Silicon without mode == 1 first.
        let mock = MockSMC(generation: .appleSiliconDirect)
        let fan = FanHardware.probeFan(0, smc: mock, lowercaseModeKey: false, platform: Self.platform(.m1))
        XCTAssertEqual(mock.mode(fan: 0), 0)

        let direct = mock.writeDouble("F0Tg", 3_000)
        XCTAssertEqual(direct, .smcResult(SMCSMCResult.badCommand.rawValue))
        _ = fan
    }

    /// The bug this covers, seen on a MacBook Pro M5 Pro: a fan travelling 0 → 7826 RPM
    /// takes seconds, so an arrival-only window declared it broken while it was visibly
    /// accelerating — the app showed an error, then the fan reached full speed anyway.
    /// Movement is what proves a fan is responding.
    func testSpinningUpFanIsConvergingNotUnresponsive() throws {
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.fanSpoolRPMPerSecond = 2_000     // leisurely: ~3 s to reach 6000 RPM
        let mock = MockSMC(options: options)

        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)
        XCTAssertEqual(mock.actualRPM(fan: 0), options.fanMinRPM, "starts at its idle speed")

        let outcome = try sequencer.setTarget(fan: fan, rpm: 6_000).get()

        XCTAssertTrue(outcome.applied, "the write succeeded")
        XCTAssertEqual(outcome.response, .converging)
        XCTAssertTrue(outcome.converging)
        XCTAssertFalse(outcome.unresponsive, "a fan that is moving is not unresponsive")
        XCTAssertFalse(outcome.verified, "it has not arrived yet, and we say so")
        XCTAssertGreaterThan(outcome.actualRPM, options.fanMinRPM, "it really did start moving")

        // And it must not have paid the whole verification window: convergence exits early.
        let clock = try XCTUnwrap(mock.clock as? VirtualSMCClock)
        XCTAssertLessThan(
            clock.totalSleepMilliseconds, 3_000,
            "a responding fan must cut the verification short"
        )
    }

    /// Reading a fan's RPM must not change it — only time does. (Regression guard for the
    /// mock itself: a per-read inertia model made probing a fan speed it up.)
    func testProbingAFanDoesNotChangeItsSpeed() throws {
        var options = MockSMC.Options()
        options.fanSpoolRPMPerSecond = 5_000
        let mock = MockSMC(options: options)

        for _ in 0..<20 { _ = mock.readDouble("F0Ac") }
        XCTAssertEqual(mock.actualRPM(fan: 0), options.fanMinRPM,
                       "reads are free; only elapsed time moves the fan")
    }

    /// The counterpart: a fan that never moves at all is still reported honestly.
    func testFanThatNeverMovesIsStalled() throws {
        let mock = MockSMC(generation: .appleSiliconDirect, fanResponds: false)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let outcome = try sequencer.setTarget(fan: fan, rpm: 5_000).get()
        XCTAssertEqual(outcome.response, .stalled)
        XCTAssertTrue(outcome.unresponsive)
        XCTAssertFalse(outcome.converging)
    }

    /// A fan already sitting at the commanded value must verify immediately.
    func testAlreadyAtTargetVerifiesWithoutWaiting() throws {
        let mock = MockSMC(generation: .appleSiliconDirect, fanSpoolRPMPerSecond: 500)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        // Already spinning at the value we are about to command.
        mock.setFanSpeed(fan: 0, actual: 4_000, target: 4_000)

        let clock = try XCTUnwrap(mock.clock as? VirtualSMCClock)
        let before = clock.totalSleepMilliseconds
        let outcome = try sequencer.setTarget(fan: fan, rpm: 4_000).get()

        XCTAssertTrue(outcome.verified)
        XCTAssertEqual(outcome.response, .atTarget)
        XCTAssertEqual(outcome.actualRPM, 4_000, accuracy: 1)
        XCTAssertLessThan(clock.totalSleepMilliseconds - before, 500,
                          "no sleep is needed when the fan is already there")
    }

    func testUnresponsiveFanIsReportedNotSilentlyIgnored() throws {
        let mock = MockSMC(generation: .appleSiliconDirect, fanResponds: false)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let outcome = try sequencer.setTarget(fan: fan, rpm: 4_000).get()
        XCTAssertTrue(outcome.applied, "the write itself is accepted")
        XCTAssertFalse(outcome.verified)
        XCTAssertEqual(outcome.response, .stalled)
        XCTAssertTrue(outcome.unresponsive, "a fan that never moves must be flagged")
    }

    func testSizeMismatchOnTargetIsVerifiedByReadBack() throws {
        // 0x87 "size mismatch" on F%dTg is often applied anyway (pitfall #3).
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.sizeMismatchOnTargetButApplies = true
        let mock = MockSMC(options: options)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        let fan = try XCTUnwrap(snapshot.fans.first)

        let outcome = try sequencer.setTarget(fan: fan, rpm: 2_500).get()
        XCTAssertTrue(outcome.applied, "read-back must rescue an 0x87 that was applied anyway")
        XCTAssertTrue(outcome.verified)
    }

    // MARK: - Release semantics

    func testReleaseClearsFtstOnlyForTheLastManualFan() throws {
        let mock = MockSMC(generation: .appleSiliconLocked)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock
        )
        let fan0 = snapshot.fans[0]
        let fan1 = snapshot.fans[1]

        XCTAssertNoThrow(try sequencer.ensureManualMode(fan0).get())
        XCTAssertNoThrow(try sequencer.ensureManualMode(fan1).get())
        XCTAssertTrue(mock.isFtstSet())

        XCTAssertNoThrow(try sequencer.releaseAuto(fan: fan0, isLastManualFan: false).get())
        XCTAssertTrue(mock.isFtstSet(), "Ftst stays held while another fan is still manual")
        XCTAssertEqual(mock.mode(fan: 0), 0)

        XCTAssertNoThrow(try sequencer.releaseAuto(fan: fan1, isLastManualFan: true).get())
        XCTAssertFalse(mock.isFtstSet(), "Ftst must be cleared when the last manual fan is released")
        XCTAssertFalse(sequencer.isFtstHeld)
    }

    func testReleaseAllLeavesNothingPinned() throws {
        let mock = MockSMC(generation: .appleSiliconLocked)
        let (sequencer, _) = makeSequencer(
            mock, generation: .m3, hasFtst: true, hasForceMask: false, unlockStyle: .ftstUnlock
        )
        XCTAssertNoThrow(try sequencer.ensureManualMode(sequencer.snapshot.fans[0]).get())
        XCTAssertNoThrow(try sequencer.ensureManualMode(sequencer.snapshot.fans[1]).get())

        let results = sequencer.releaseAll()
        XCTAssertEqual(results.count, 2)
        for (_, result) in results { XCTAssertNoThrow(try result.get()) }
        XCTAssertFalse(mock.isFtstSet())
        XCTAssertEqual(mock.mode(fan: 0), 0)
        XCTAssertEqual(mock.mode(fan: 1), 0)
    }

    func testReassertRestoresManualModeAndTargets() throws {
        let mock = MockSMC(generation: .appleSiliconDirect)
        let (sequencer, snapshot) = makeSequencer(
            mock, generation: .m1, hasFtst: false, hasForceMask: false, unlockStyle: .direct
        )
        XCTAssertNoThrow(try sequencer.setTarget(fan: snapshot.fans[0], rpm: 3_500).get())

        // The daemon reclaims the fan.
        mock.setNumeric("F0Md", 0)
        let results = sequencer.reassert(desired: [0: 3_500])
        XCTAssertNoThrow(try XCTUnwrap(results[0]).get())
        XCTAssertEqual(mock.mode(fan: 0), 1)
        XCTAssertEqual(mock.actualRPM(fan: 0), 3_500, accuracy: 1)
    }

    // MARK: - Fanless machines

    func testFanlessMachineProbesCleanly() throws {
        var options = MockSMC.Options()
        options.generation = .appleSiliconDirect
        options.fanCount = 0
        let mock = MockSMC(options: options)
        let snapshot = FanHardware.probe(mock, platform: Self.platform(.m1))

        XCTAssertEqual(snapshot.fanCount, 0)
        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertFalse(snapshot.hasFans)
        XCTAssertEqual(snapshot.unlockStyle, .unavailable, "nothing to unlock without fans")

        // Monitoring still works: the mock's sensors are still readable.
        let scan = SensorScanner.scan(mock, platform: Self.platform(.m1), fans: snapshot)
        XCTAssertFalse(scan.temperatureSamples.isEmpty)
    }
}

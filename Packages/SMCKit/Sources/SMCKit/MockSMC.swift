//
//  MockSMC.swift
//  SMCKit
//
//  A scriptable, generation-aware AppleSMC simulator.
//
//  Hardware access cannot be exercised in CI (PROMPT.md operating rule #3), so the
//  unlock state machine, the fan layer and the curve engine are all driven against
//  this mock. It deliberately models the awkward realities rather than just storing
//  bytes: mode 3 locking on M3/M4, the `Ftst` yield delay, lowercase `F0md` on M5,
//  the Intel `FS! ` bitmask, firmware rejections (0x82/0x84/0x86/0x87) and a fan
//  that does not physically respond.
//

import Foundation

public final class MockSMC: SMCAccess {

    // MARK: - Generation model

    /// The hardware generations whose behaviour the mock reproduces.
    public enum Generation: String, Sendable {
        /// Intel / T2: `F%dMd` + `FS! ` bitmask, `fpe2` fan values.
        case intel
        /// M1 (and anything that accepts a direct mode write): `F%dMd`, no unlock.
        case appleSiliconDirect
        /// M3/M4: firmware holds mode 3 and rejects mode writes with 0x82 until
        /// `Ftst = 1`, after which the daemon yields a few seconds later.
        case appleSiliconLocked
        /// A hypothetical machine that refuses manual mode AND has no `Ftst`.
        case appleSiliconLockedNoFtst
        /// M5: lowercase `F%dmd`, no `Ftst`, direct writes succeed.
        case appleSiliconLowercase
    }

    public struct Options {
        public var generation: Generation = .appleSiliconDirect
        public var fanCount: Int = 2
        /// How long after `Ftst = 1` the thermal daemon yields (PROMPT.md §4.6: ~3 s).
        public var lockYieldMilliseconds: Int = 3_000
        /// When false, `F%dAc` never follows `F%dTg` — the "fan did not respond" case.
        public var fanResponds: Bool = true
        /// How fast the simulated fan travels toward its target, in RPM per *second of
        /// virtual time*. 0 = instantaneous, which is what most tests want.
        ///
        /// Driven by the clock rather than by reads, because reading an RPM does not change
        /// it: only time does. (Advancing per read made merely probing a fan speed it up,
        /// which is not a thing that happens.)
        public var fanSpoolRPMPerSecond: Double = 0
        /// Seconds a stopped fan takes before it starts turning at all — static friction.
        /// Real fans idle at 0 RPM on Apple Silicon and take several seconds to break free.
        public var fanStartupDelaySeconds: Double = 0
        /// When true, `F%dTg` writes answer 0x87 but the value is applied anyway
        /// (PROMPT.md §4.1 — read it back before declaring failure).
        public var sizeMismatchOnTargetButApplies: Bool = false
        public var fanMinRPM: Double = 1_200
        public var fanMaxRPM: Double = 6_000

        public init() {}
    }

    /// A one-shot scripted write failure, used by tests that need a specific error.
    public struct WriteRule {
        public var key: String
        public var result: SMCWriteResult
        public var times: Int
        public init(key: String, result: SMCWriteResult, times: Int = 1) {
            self.key = key
            self.result = result
            self.times = times
        }
    }

    // MARK: - Observable state

    public var options: Options
    /// The clock the mock reads for its yield timing. Share it with the sequencer so
    /// virtual sleeps advance the simulated daemon.
    public let clock: SMCClock

    public private(set) var writeHistory: [(key: String, bytes: [UInt8], result: SMCWriteResult)] = []
    public private(set) var readHistory: [String] = []
    /// Scripted failures consumed in order before normal handling.
    public var writeRules: [WriteRule] = []
    /// When non-nil, every write returns this IOKit error (simulates non-root writes).
    public var iokitErrorForWrites: kern_return_t?
    /// When false, every operation behaves as if the user client is not open.
    public var simulatesConnection = true

    private var storage: [String: (type: String, size: Int, bytes: [UInt8])] = [:]
    /// fan index → target RPM as last accepted by the firmware.
    private var fanTarget: [Int: Double] = [:]
    /// fan index → actual RPM.
    private var fanActual: [Int: Double] = [:]
    private var fanMode: [Int: Int] = [:]
    /// When each fan's actual RPM was last recomputed, so travel can be time-based.
    private var fanAdvancedAt: [Int: TimeInterval] = [:]
    /// Virtual time at which each fan is allowed to start moving.
    private var fanStartsMovingAt: [Int: TimeInterval] = [:]
    private var ftst: Bool = false
    private var unlockedAt: TimeInterval?

    // MARK: - Init

    public init(options: Options = Options(), clock: SMCClock = VirtualSMCClock()) {
        self.options = options
        self.clock = clock
        seedHardware()
    }

    /// Convenience factory: `MockSMC(generation: .appleSiliconLocked, fans: 2)`.
    public convenience init(
        generation: Generation,
        fans: Int = 2,
        fanResponds: Bool = true,
        fanSpoolRPMPerSecond: Double = 0,
        clock: SMCClock = VirtualSMCClock()
    ) {
        var options = Options()
        options.generation = generation
        options.fanCount = fans
        options.fanResponds = fanResponds
        options.fanSpoolRPMPerSecond = fanSpoolRPMPerSecond
        self.init(options: options, clock: clock)
    }

    // MARK: - Seeding

    private var modeKeyFormat: String {
        options.generation == .appleSiliconLowercase ? "F%dmd" : "F%dMd"
    }

    private var fanValueType: String {
        options.generation == .intel ? "fpe2" : "flt "
    }

    public var hasFtst: Bool {
        options.generation == .appleSiliconLocked
    }

    public var hasForceMask: Bool { options.generation == .intel }

    /// (Re)creates the simulated key space for the configured generation.
    public func seedHardware() {
        storage.removeAll()
        fanTarget.removeAll()
        fanActual.removeAll()
        fanMode.removeAll()
        ftst = false
        unlockedAt = nil

        store("#KEY", type: "ui32", size: 4, bytes: be32(UInt32(0))) // patched below
        store("FNum", type: "ui8 ", size: 1, bytes: [UInt8(options.fanCount)])

        for index in 0..<options.fanCount {
            store(String(format: modeKeyFormat, index), type: "ui8 ", size: 1, bytes: [3])
            store("F\(index)ID", type: "{fds", size: 16, bytes: nameBytes(index == 0 ? "Left fan" : "Right fan"))
            store("F\(index)Ac", type: fanValueType, size: options.generation == .intel ? 2 : 4,
                  bytes: encodeFan(fanMin(index)))
            store("F\(index)Mn", type: fanValueType, size: options.generation == .intel ? 2 : 4,
                  bytes: encodeFan(fanMin(index)))
            store("F\(index)Mx", type: fanValueType, size: options.generation == .intel ? 2 : 4,
                  bytes: encodeFan(fanMax(index)))
            store("F\(index)Tg", type: fanValueType, size: options.generation == .intel ? 2 : 4,
                  bytes: encodeFan(fanMin(index)))
            fanMode[index] = options.generation == .appleSiliconLocked
                || options.generation == .appleSiliconLockedNoFtst ? 3 : 0
            fanActual[index] = fanMin(index)
            fanTarget[index] = fanMin(index)
            fanAdvancedAt[index] = clock.now
        }

        if hasFtst { store("Ftst", type: "ui8 ", size: 1, bytes: [0]) }
        if hasForceMask { store("FS! ", type: "ui16", size: 2, bytes: [0x00, 0x00]) }

        // Some sensors so the scanner tests have something to chew on.
        store("TC0P", type: "sp78", size: 2, bytes: [0x32, 0x00])  // 50.0 °C
        store("Tp01", type: "sp78", size: 2, bytes: [0x37, 0x00])  // 55.0 °C
        store("Tg0D", type: "sp78", size: 2, bytes: [0x30, 0x00])  // 48.0 °C
        store("TB0T", type: "sp78", size: 2, bytes: [0x2D, 0x00])  // 45.0 °C
        store("VP0R", type: "ui16", size: 2, bytes: [0x2C, 0x8A])  // ~11402 mV
        store("ID0R", type: "sp78", size: 2, bytes: [0x00, 0x80])

        let count = UInt32(storage.count)
        storage["#KEY"] = ("ui32", 4, be32(count))
    }

    // MARK: - Test helpers

    /// Overwrites a key's raw payload (also usable to introduce a brand-new key).
    public func seed(_ key: String, dataType: String, byteCount: Int, bytes: [UInt8]) {
        store(key, type: dataType, size: byteCount, bytes: bytes)
        let count = UInt32(storage.count)
        storage["#KEY"] = ("ui32", 4, be32(count))
    }

    public func setNumeric(_ key: String, _ value: Double) {
        guard let existing = storage[key] else { return }
        let bytes = (try? SMCCodecs.encode(double: value, dataType: existing.type, byteCount: existing.size))
            ?? existing.bytes
        storage[key] = (existing.type, existing.size, bytes)
    }

    /// Simulates the firmware refusing manual mode because no unlock key exists.
    public func removeKey(_ key: String) {
        storage.removeValue(forKey: key)
        let count = UInt32(storage.count)
        storage["#KEY"] = ("ui32", 4, be32(count))
    }

    /// The last RPM the firmware accepted for a fan.
    public func targetRPM(fan: Int) -> Double { fanTarget[fan] ?? 0 }

    /// The RPM the simulated fan is actually spinning at.
    public func actualRPM(fan: Int) -> Double { fanActual[fan] ?? 0 }

    /// The mode the hardware currently reports for a fan.
    public func mode(fan: Int) -> Int { fanMode[fan] ?? 0 }

    public func isFtstSet() -> Bool { ftst }

    public func writes(forKey key: String) -> [(key: String, bytes: [UInt8], result: SMCWriteResult)] {
        writeHistory.filter { $0.key == key }
    }

    // MARK: - SMCAccess

    public var isConnected: Bool { simulatesConnection }

    public func keyInfo(_ key: String) -> SMCKeyInfo? {
        guard simulatesConnection, let stored = storage[key] else { return nil }
        return SMCKeyInfo(key: key, dataSize: UInt32(stored.size), dataType: stored.type, dataAttributes: 0xC1)
    }

    public func keyInfoThrowing(_ key: String) throws -> SMCKeyInfo {
        guard simulatesConnection else { throw SMCError.notConnected }
        guard let info = keyInfo(key) else { throw SMCError.smc(key, .notFound) }
        return info
    }

    public func allKeys() -> [String] {
        guard simulatesConnection else { return [] }
        return storage.keys.sorted()
    }

    public func invalidateCaches() { /* the mock has no caches to drop */ }

    public func read(_ key: String) -> SMCReading? {
        try? readThrowing(key)
    }

    public func readThrowing(_ key: String) throws -> SMCReading {
        guard simulatesConnection else { throw SMCError.notConnected }
        readHistory.append(key)

        if let computed = computedRead(key) { return computed }

        guard let stored = storage[key] else { throw SMCError.smc(key, .notFound) }
        let value = try SMCCodecs.decode(
            dataType: stored.type,
            bytes: stored.bytes,
            byteCount: stored.size,
            plausibleRange: key.first == "F" ? 0...20_000 : (key.first == "T" ? -100...250 : nil)
        )
        return SMCReading(
            key: key,
            keyInfo: SMCKeyInfo(key: key, dataSize: UInt32(stored.size), dataType: stored.type, dataAttributes: 0xC1),
            bytes: stored.bytes,
            value: value
        )
    }

    public func write(_ key: String, value: SMCValue) -> SMCWriteResult {
        guard let info = keyInfo(key) else { return .smcResult(SMCSMCResult.notFound.rawValue) }
        do {
            let bytes = try SMCCodecs.encode(value, dataType: info.dataType, byteCount: Int(info.dataSize))
            return writeRaw(key, bytes: bytes)
        } catch {
            return .encodingFailed("\(key): \(error.localizedDescription)")
        }
    }

    public func writeRaw(_ key: String, bytes: [UInt8]) -> SMCWriteResult {
        let result = evaluateWrite(key, bytes: bytes)
        writeHistory.append((key: key, bytes: bytes, result: result))

        // 0x87 on F%dTg is the size-mismatch answer that is *often applied anyway*
        // (PROMPT.md §4.1) — model that so the read-back rescue path is exercised.
        let appliedAnyway = options.sizeMismatchOnTargetButApplies && result.smcCode == .sizeMismatch
        if result.isSuccess || appliedAnyway { applyWrite(key, bytes: bytes) }
        return result
    }

    // MARK: - Write evaluation (the simulated firmware)

    private func evaluateWrite(_ key: String, bytes: [UInt8]) -> SMCWriteResult {
        guard simulatesConnection else { return .notConnected }
        if let iokit = iokitErrorForWrites { return .iokit(iokit) }

        // Consume any scripted rule first.
        if let index = writeRules.firstIndex(where: { $0.key == key && $0.times > 0 }) {
            var rule = writeRules[index]
            rule.times -= 1
            writeRules[index] = rule
            return rule.result
        }

        guard storage[key] != nil else { return .smcResult(SMCSMCResult.notFound.rawValue) }

        // Mode keys.
        if fanIndex(ofModeKey: key) != nil {
            let requested = Int(bytes.first ?? 0)
            guard requested == 1 else { return .ok }   // back to auto always succeeds
            switch options.generation {
            case .intel, .appleSiliconDirect:
                return .ok
            case .appleSiliconLowercase:
                return .ok
            case .appleSiliconLockedNoFtst:
                return .smcResult(SMCSMCResult.badCommand.rawValue)
            case .appleSiliconLocked:
                guard ftst else { return .smcResult(SMCSMCResult.badCommand.rawValue) }
                guard let unlockedAt, clock.now >= unlockedAt else {
                    return .smcResult(SMCSMCResult.badCommand.rawValue)
                }
                return .ok
            }
        }

        // Ftst unlock key.
        if key == "Ftst" {
            guard hasFtst else { return .smcResult(SMCSMCResult.notFound.rawValue) }
            if bytes.first == 1, !ftst {
                ftst = true
                unlockedAt = clock.now + Double(options.lockYieldMilliseconds) / 1000.0
            } else if bytes.first == 0 {
                ftst = false
                unlockedAt = nil
            }
            return .ok
        }

        // Fan targets: on Apple Silicon the firmware rejects a target while the fan
        // is not in manual mode (pitfall #6).
        if let fan = fanIndex(ofTargetKey: key) {
            if options.generation != .intel, (fanMode[fan] ?? 0) != 1 {
                return .smcResult(SMCSMCResult.badCommand.rawValue)
            }
            if options.sizeMismatchOnTargetButApplies {
                return .smcResult(SMCSMCResult.sizeMismatch.rawValue)
            }
            return .ok
        }

        // Intel force mask.
        if key == "FS! " { return hasForceMask ? .ok : .smcResult(SMCSMCResult.notFound.rawValue) }

        return .ok
    }

    private func applyWrite(_ key: String, bytes: [UInt8]) {
        guard var stored = storage[key] else { return }

        if let fan = fanIndex(ofModeKey: key) {
            fanMode[fan] = Int(bytes.first ?? 0)
            return
        }
        if key == "Ftst" {
            ftst = bytes.first == 1
            return
        }
        if key == "FS! " {
            stored.bytes = pad(bytes, stored.size)
            storage[key] = stored
            return
        }
        if let fan = fanIndex(ofTargetKey: key) {
            let rpm = decodeFan(bytes, type: stored.type)
            let wasStopped = (fanActual[fan] ?? 0) <= 100
            fanTarget[fan] = rpm
            if wasStopped, rpm > 100, options.fanStartupDelaySeconds > 0 {
                fanStartsMovingAt[fan] = clock.now + options.fanStartupDelaySeconds
            }
            stored.bytes = pad(bytes, stored.size)
            storage[key] = stored
            // With inertia configured, the fan does NOT teleport to the new target: it
            // travels there as virtual time passes (see advanceFanIfNeeded).
            if options.fanResponds, options.fanSpoolRPMPerSecond == 0 {
                fanActual[fan] = rpm
                if var actual = storage["F\(fan)Ac"] {
                    actual.bytes = encodeFan(rpm)
                    storage["F\(fan)Ac"] = actual
                }
            }
            return
        }

        stored.bytes = pad(bytes, stored.size)
        storage[key] = stored
    }

    // MARK: - Computed reads (mode / actual RPM)

    private func computedRead(_ key: String) -> SMCReading? {
        if let fan = fanIndex(ofModeKey: key) {
            let mode = reportedMode(fan)
            let info = SMCKeyInfo(key: key, dataSize: 1, dataType: "ui8 ", dataAttributes: 0xC1)
            return SMCReading(key: key, keyInfo: info, bytes: [UInt8(mode)], value: .double(Double(mode)))
        }
        if let fan = fanIndex(ofActualKey: key) {
            // Model inertia: travel is a function of elapsed time, so reading a fan does
            // not change it and a fan commanded to 7800 RPM is still climbing a second
            // later — exactly the situation that used to be misreported as "no response".
            advanceFanIfNeeded(fan)
            let rpm = fanActual[fan] ?? 0
            let info = SMCKeyInfo(key: key, dataSize: options.generation == .intel ? 2 : 4,
                                  dataType: fanValueType, dataAttributes: 0xC0)
            return SMCReading(key: key, keyInfo: info, bytes: encodeFan(rpm), value: .double(rpm))
        }
        return nil
    }

    /// Mode 3 is what the daemon reports while it owns thermals; it drops to 0 once it
    /// yields, and becomes 1 once we successfully command manual mode.
    private func reportedMode(_ fan: Int) -> Int {
        let mode = fanMode[fan] ?? 0
        guard options.generation == .appleSiliconLocked else { return mode }

        if mode == 1 { return 1 }                       // we own it
        if ftst, let unlockedAt, clock.now >= unlockedAt { return 0 }
        return 3                                        // daemon holds it
    }

    /// Moves a fan toward its target by however much virtual time has passed.
    private func advanceFanIfNeeded(_ fan: Int) {
        defer { fanAdvancedAt[fan] = clock.now }
        // A fan that ignores commands must not follow the target — not even instantly.
        guard options.fanResponds else { return }
        // Static friction: nothing moves until the startup delay has elapsed.
        if let startsAt = fanStartsMovingAt[fan], clock.now < startsAt { return }
        guard options.fanSpoolRPMPerSecond > 0 else {
            fanActual[fan] = fanTarget[fan] ?? fanActual[fan] ?? 0   // instantaneous
            return
        }
        let target = fanTarget[fan] ?? 0
        let current = fanActual[fan] ?? 0
        let elapsed = max(0, clock.now - (fanAdvancedAt[fan] ?? clock.now))
        let travel = options.fanSpoolRPMPerSecond * elapsed
        guard travel > 0, current != target else { return }
        if current < target {
            fanActual[fan] = min(target, current + travel)
        } else {
            fanActual[fan] = max(target, current - travel)
        }
    }

    /// Test setup: force a fan's current speed (and the target it is travelling to).
    /// Use this instead of trying to spin a fan up read by read.
    public func setFanSpeed(fan: Int, actual: Double, target: Double? = nil) {
        fanActual[fan] = actual
        if let target { fanTarget[fan] = target }
        fanAdvancedAt[fan] = clock.now
    }

    // MARK: - Small helpers

    private func fanIndex(ofModeKey key: String) -> Int? {
        guard key.count == 4, key.hasPrefix("F"), key.hasSuffix("Md") || key.hasSuffix("md") else { return nil }
        return Int(String(Array(key)[1]))
    }

    private func fanIndex(ofTargetKey key: String) -> Int? {
        guard key.count == 4, key.hasPrefix("F"), key.hasSuffix("Tg") else { return nil }
        return Int(String(Array(key)[1]))
    }

    /// `F%dAc` — the actual RPM. Kept separate from `fanIndex(ofTargetKey:)` on purpose:
    /// reusing the target resolver for `Ac` silently returns nil (wrong suffix), which
    /// makes every actual-RPM read fall through to the stored bytes.
    private func fanIndex(ofActualKey key: String) -> Int? {
        guard key.count == 4, key.hasPrefix("F"), key.hasSuffix("Ac") else { return nil }
        return Int(String(Array(key)[1]))
    }

    private func store(_ key: String, type: String, size: Int, bytes: [UInt8]) {
        storage[key] = (type, size, pad(bytes, size))
    }

    private func pad(_ bytes: [UInt8], _ size: Int) -> [UInt8] {
        var result = Array(bytes.prefix(size))
        if result.count < size { result += [UInt8](repeating: 0, count: size - result.count) }
        return result
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func nameBytes(_ name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ascii = Array(name.utf8.prefix(12))
        bytes.replaceSubrange(4..<(4 + ascii.count), with: ascii)
        return bytes
    }

    private func encodeFan(_ rpm: Double) -> [UInt8] {
        (try? SMCCodecs.encode(
            double: rpm,
            dataType: fanValueType,
            byteCount: options.generation == .intel ? 2 : 4
        )) ?? [0, 0, 0, 0]
    }

    private func decodeFan(_ bytes: [UInt8], type: String) -> Double {
        (try? SMCCodecs.decode(dataType: type, bytes: bytes, byteCount: bytes.count))?.doubleValue ?? 0
    }

    private func fanMin(_ index: Int) -> Double { options.fanMinRPM + Double(index) * 100 }
    private func fanMax(_ index: Int) -> Double { options.fanMaxRPM + Double(index) * 100 }
}

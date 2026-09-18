//
//  SMCAccess.swift
//  SMCKit
//
//  The mockable seam (PROMPT.md §5.2, operating rule #3): everything that touches
//  the SMC sits behind this protocol, so the app, the helper and the test suite can
//  all drive the same logic with `MockSMC` instead of real hardware.
//

import Foundation

/// Read/write access to AppleSMC.
///
/// Implementations must be safe to call from any thread; `SMCConnection` serialises
/// all operations on a dedicated queue.
public protocol SMCAccess: AnyObject {
    /// True when the IOKit user client is open and usable.
    var isConnected: Bool { get }

    /// Key metadata, or nil when the key does not exist on this Mac (SMC 0x84).
    func keyInfo(_ key: String) -> SMCKeyInfo?

    /// Key metadata, throwing `SMCError.smc(_, .notFound)` for missing keys so that
    /// callers can distinguish "absent" from "the connection broke".
    func keyInfoThrowing(_ key: String) throws -> SMCKeyInfo

    /// Every key name the SMC reports (enumerated via `#KEY` + command 8).
    func allKeys() -> [String]

    /// Reads and decodes a key. Nil when the key is absent or the read fails.
    func read(_ key: String) -> SMCReading?

    /// Reads and decodes a key, surfacing the precise failure.
    func readThrowing(_ key: String) throws -> SMCReading

    /// Writes a decoded value. The payload is sized from the key's `dataSize`.
    func write(_ key: String, value: SMCValue) -> SMCWriteResult

    /// Writes a raw payload (padded/truncated to the key's `dataSize`).
    func writeRaw(_ key: String, bytes: [UInt8]) -> SMCWriteResult

    /// Drops cached key metadata and the key list (call after wake).
    func invalidateCaches()
}

// MARK: - Convenience

public extension SMCAccess {

    /// `true` when the key exists on this machine.
    func exists(_ key: String) -> Bool { keyInfo(key) != nil }

    /// Reads a numeric key.
    func readDouble(_ key: String) -> Double? { read(key)?.doubleValue }

    /// Reads a string key (`{fds` fan names).
    func readString(_ key: String) -> String? { read(key)?.stringValue }

    /// Reads a key as an integer where one is expected (`ui8`/`ui16`/`ui32` modes).
    func readInt(_ key: String) -> Int? {
        guard let double = readDouble(key), double.isFinite else { return nil }
        return Int(double.rounded())
    }

    /// Encodes and writes a numeric value using the key's own data type and size.
    @discardableResult
    func writeDouble(_ key: String, _ value: Double) -> SMCWriteResult {
        guard let info = keyInfo(key) else { return .smcResult(SMCSMCResult.notFound.rawValue) }
        do {
            let bytes = try SMCCodecs.encode(double: value, dataType: info.dataType, byteCount: Int(info.dataSize))
            return writeRaw(key, bytes: bytes)
        } catch {
            return .encodingFailed("\(key): \(error.localizedDescription)")
        }
    }

    /// Writes a single byte (`ui8` keys such as mode keys and `Ftst`).
    @discardableResult
    func writeByte(_ key: String, _ value: UInt8) -> SMCWriteResult {
        writeRaw(key, bytes: [value])
    }

    /// True when a read succeeds and returns non-zero numeric data.
    func hasValue(_ key: String) -> Bool {
        guard let reading = read(key), let double = reading.doubleValue else { return false }
        return double != 0
    }
}

// MARK: - Clock / sleeping seam

/// Time and sleeping seam so the unlock state machine is testable with a virtual clock
/// (no real 30-second waits in CI, no flaky timing).
public protocol SMCClock: AnyObject {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    /// Suspends the caller for the given number of milliseconds.
    func sleep(milliseconds: Int)
}

/// Production clock: reads the monotonic uptime clock and really sleeps.
public final class SystemSMCClock: SMCClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        usleep(UInt32(milliseconds) * 1000)
    }

    /// Async-friendly sleep that does not block a cooperative thread.
    public func sleepAsync(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

/// Deterministic clock for tests and for the mock SMC: `sleep` advances virtual time
/// instead of blocking, so a simulated 30-second unlock completes instantly.
public final class VirtualSMCClock: SMCClock {
    private(set) public var elapsedMilliseconds: Int = 0
    public private(set) var sleepCalls: [Int] = []

    public init() {}

    public var now: TimeInterval { Double(elapsedMilliseconds) / 1000.0 }

    public func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        sleepCalls.append(milliseconds)
        elapsedMilliseconds += milliseconds
    }

    /// Total virtual time spent sleeping — used by FSM tests to assert the retry budget.
    public var totalSleepMilliseconds: Int { elapsedMilliseconds }
}

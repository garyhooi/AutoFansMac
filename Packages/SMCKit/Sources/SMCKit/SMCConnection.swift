//
//  SMCConnection.swift
//  SMCKit
//
//  The real IOKit implementation: one AppleSMC user client for the process
//  lifetime, every call serialised on a dedicated queue, with a single transparent
//  reconnect when the connection dies (a common aftermath of sleep/wake).
//
//  Reads work unprivileged from any non-sandboxed process. Writes need root; a
//  non-root write surfaces as `kIOReturnNotPrivileged (0xe00002c2)`, which is
//  exactly the signal that the privileged helper must perform it instead.
//

import Foundation
import IOKit

public final class SMCConnection: SMCAccess {

    // MARK: - Statistics (diagnostics)

    public struct Statistics: Sendable, Equatable {
        public var callCount = 0
        public var errorCount = 0
        public var reconnectCount = 0
        public var lastError: String?
    }

    /// Counters surfaced in the app's diagnostics export.
    public private(set) var statistics = Statistics()

    // MARK: - State

    /// All SMC traffic is serialised here. IOKit user clients are not documented as
    /// thread safe, and interleaving command 9/5 pairs from two threads is a known
    /// way to get spurious 0x80/0x81 results.
    private let queue = DispatchQueue(label: "com.autofansmac.smckit.connection", qos: .userInitiated)

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: SMCKeyInfo] = [:]
    private var knownMissingKeys: Set<String> = []
    private var cachedKeys: [String]?
    private var cachedKeyCount: Int?

    public init() {}

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Lifecycle

    public var isConnected: Bool {
        queue.sync { connection != 0 }
    }

    /// Opens the AppleSMC user client. Idempotent.
    @discardableResult
    public func connect() -> Bool {
        queue.sync {
            do {
                try ensureConnected()
                return true
            } catch {
                statistics.lastError = error.localizedDescription
                return false
            }
        }
    }

    public func disconnect() {
        queue.sync { closeConnection() }
    }

    /// Drops cached key metadata and the enumerated key list. Called after wake.
    public func invalidateCaches() {
        queue.sync {
            keyInfoCache.removeAll()
            knownMissingKeys.removeAll()
            cachedKeys = nil
            cachedKeyCount = nil
        }
    }

    public func snapshotStatistics() -> Statistics { queue.sync { statistics } }

    // MARK: - SMCAccess

    public func keyInfo(_ key: String) -> SMCKeyInfo? {
        queue.sync {
            do { return try cachedKeyInfo(key) }
            catch { recordIfUnexpected(error); return nil }
        }
    }

    public func keyInfoThrowing(_ key: String) throws -> SMCKeyInfo {
        try queue.sync { try cachedKeyInfo(key) }
    }

    public func allKeys() -> [String] {
        queue.sync {
            if let cached = cachedKeys { return cached }
            guard let keyCount = try? readKeyCount() else { return [] }
            var keys: [String] = []
            keys.reserveCapacity(keyCount)
            for index in 0..<keyCount {
                guard let name = try? readKeyName(at: index), isValidKeyName(name) else { continue }
                keys.append(name)
            }
            cachedKeys = keys
            cachedKeyCount = keyCount
            return keys
        }
    }

    /// How many keys `#KEY` reports (may exceed `allKeys().count` if some indices
    /// return no usable name).
    public func keyCount() -> Int? {
        queue.sync { try? readKeyCount() }
    }

    public func read(_ key: String) -> SMCReading? {
        queue.sync {
            do { return try performRead(key) }
            catch { recordIfUnexpected(error); return nil }
        }
    }

    public func readThrowing(_ key: String) throws -> SMCReading {
        try queue.sync { try performRead(key) }
    }

    public func write(_ key: String, value: SMCValue) -> SMCWriteResult {
        guard let info = keyInfo(key) else { return .smcResult(SMCSMCResult.notFound.rawValue) }
        do {
            let bytes = try SMCCodecs.encode(value, dataType: info.dataType, byteCount: Int(info.dataSize))
            return writeRaw(key, bytes: bytes)
        } catch {
            return .encodingFailed(error.localizedDescription)
        }
    }

    public func writeRaw(_ key: String, bytes: [UInt8]) -> SMCWriteResult {
        queue.sync {
            guard let code = FourCC.encode(key) else { return .encodingFailed("invalid key \(key)") }
            // Size the payload from the key when known; fall back to what we were given.
            let size = (keyInfoCache[key]?.dataSize).map(Int.init) ?? bytes.count
            var payload = Array(bytes.prefix(max(size, 1)))
            if payload.count < size { payload += [UInt8](repeating: 0, count: size - payload.count) }

            var input = SMCKeyData_t()
            input.key = code
            input.data8 = SMCCommand.writeBytes.rawValue
            input.keyInfo.dataSize = IOByteCount32(payload.count)
            input.setBytes(payload)

            do {
                let output = try rawCall(input)
                guard output.result == 0 else {
                    // The firmware rejected the write; report the SMC status byte.
                    return .smcResult(output.result)
                }
                return .ok
            } catch SMCError.callFailed(_, let code) {
                // `rawCall` already recorded this one.
                return .iokit(code)
            } catch {
                recordIfUnexpected(error)
                return .iokit(kIOReturnError)
            }
        }
    }

    // MARK: - Primitives (must be called on `queue`)

    private func ensureConnected() throws {
        guard connection == 0 else { return }

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSMC")
        let matchingResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingResult == kIOReturnSuccess else { throw SMCError.openFailed(matchingResult) }
        defer { IOObjectRelease(iterator) }

        let device = IOIteratorNext(iterator)
        guard device != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(device) }

        var newConnection: io_connect_t = 0
        let openResult = IOServiceOpen(device, mach_task_self_, 0, &newConnection)
        guard openResult == kIOReturnSuccess else {
            let error = SMCError.openFailed(openResult)
            record(error)
            throw error
        }
        connection = newConnection
    }

    private func closeConnection() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// One `IOConnectCallStructMethod` call, with a single reconnect-and-retry when
    /// the failure looks like a dead connection rather than a firmware answer.
    private func rawCall(_ input: SMCKeyData_t) throws -> SMCKeyData_t {
        var attempt = 0
        while true {
            try ensureConnected()

            var mutableInput = input
            var output = SMCKeyData_t()
            var outputSize = MemoryLayout<SMCKeyData_t>.stride
            let result = IOConnectCallStructMethod(
                connection,
                kSMCKernelSelector,
                &mutableInput,
                MemoryLayout<SMCKeyData_t>.stride,
                &output,
                &outputSize
            )

            statistics.callCount += 1

            if result == kIOReturnSuccess { return output }

            if attempt == 0, Self.isDeadConnection(result) {
                statistics.reconnectCount += 1
                closeConnection()
                attempt += 1
                continue
            }

            let error = SMCError.callFailed(selector: kSMCKernelSelector, code: result)
            record(error)
            throw error
        }
    }

    /// Cached key metadata. MUST be called on `queue` (public wrappers take it).
    private func cachedKeyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        if knownMissingKeys.contains(key) { throw SMCError.smc(key, .notFound) }
        do {
            return try fetchKeyInfo(key)
        } catch SMCError.smc(_, let result) where result.isNotFound {
            knownMissingKeys.insert(key)
            throw SMCError.smc(key, result)
        }
    }

    /// Reads key metadata via command 9 (filling `keyInfo`).
    private func fetchKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard let code = FourCC.encode(key) else { throw SMCError.badKey(key) }

        var input = SMCKeyData_t()
        input.key = code
        input.data8 = SMCCommand.readKeyInfo.rawValue

        let output = try rawCall(input)
        guard output.result == 0 else {
            throw SMCError.smc(key, output.smcResult)
        }

        let info = SMCKeyInfo(
            key: key,
            dataSize: output.keyInfo.dataSize,
            dataType: output.dataTypeString,
            dataAttributes: output.keyInfo.dataAttributes
        )
        keyInfoCache[key] = info
        knownMissingKeys.remove(key)
        return info
    }

    /// The documented read protocol: command 9 first (for the size), then command 5.
    private func performRead(_ key: String) throws -> SMCReading {
        guard let code = FourCC.encode(key) else { throw SMCError.badKey(key) }
        let info = try cachedKeyInfo(key)

        var input = SMCKeyData_t()
        input.key = code
        input.data8 = SMCCommand.readBytes.rawValue
        input.keyInfo.dataSize = info.dataSize

        let output = try rawCall(input)
        guard output.result == 0 else {
            throw SMCError.smc(key, output.smcResult)
        }

        // Copy out min(dataSize, 32) bytes — never more than the struct holds.
        let byteCount = min(Int(info.dataSize), 32)
        let bytes = Array(output.byteArray.prefix(max(byteCount, 1)))

        let value: SMCValue
        do {
            value = try SMCCodecs.decode(
                dataType: info.dataType,
                bytes: bytes,
                byteCount: byteCount,
                plausibleRange: Self.plausibleRange(for: key, dataType: info.dataType)
            )
        } catch {
            throw SMCError.decodeFailed(key: key, dataType: info.dataType, bytes: bytes)
        }

        return SMCReading(key: key, keyInfo: info, bytes: bytes, value: value)
    }

    private func readKeyCount() throws -> Int {
        let reading = try performRead("#KEY")
        guard let count = reading.doubleValue, count.isFinite, count >= 0, count <= 100_000 else {
            throw SMCError.decodeFailed(key: "#KEY", dataType: reading.dataType, bytes: reading.bytes)
        }
        return Int(count)
    }

    private func readKeyName(at index: Int) throws -> String {
        var input = SMCKeyData_t()
        input.data8 = SMCCommand.readIndex.rawValue
        input.data32 = UInt32(index)
        let output = try rawCall(input)
        return output.keyString
    }

    // MARK: - Helpers

    /// A key name must be 4 printable ASCII characters; SMC returns 0/garbage for
    /// indices that hold no key.
    private func isValidKeyName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 4 else { return false }
        return bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// Per-key plausibility ranges for the `flt ` byte-swap fallback: a fan RPM or a
    /// temperature decoded outside these bounds is treated as a byte-order problem.
    private static func plausibleRange(for key: String, dataType: String) -> ClosedRange<Double>? {
        guard SMCCodecs.normalize(dataType) == "flt" else { return nil }
        guard let first = key.first else { return nil }
        if first == "F" { return 0...20_000 }          // fan RPM
        if first == "T" { return -100...250 }          // temperature
        return nil
    }

    private static func isDeadConnection(_ code: kern_return_t) -> Bool {
        switch code {
        case kIOReturnNoDevice,
             kIOReturnNotOpen,
             kIOReturnNotAttached,
             kIOReturnExclusiveAccess,
             kIOReturnAborted,
             kIOReturnOffline:
            return true
        default:
            return false
        }
    }

    private func record(_ error: Error) {
        statistics.errorCount += 1
        statistics.lastError = error.localizedDescription
    }

    /// Records a failure *unless* it is SMC 0x84.
    ///
    /// "Key not found" is the documented way to probe whether an optional key exists
    /// (`Ftst`, lowercase `F0md`, `F1ID` on a machine that only names fan 0). Counting
    /// those as errors buried the real ones: a diagnostics export showed 765 "errors",
    /// every one of them a successful probe.
    private func recordIfUnexpected(_ error: Error) {
        if case SMCError.smc(_, let result) = error, result.isNotFound { return }
        record(error)
    }
}

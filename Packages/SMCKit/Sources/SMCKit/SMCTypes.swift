//
//  SMCTypes.swift
//  SMCKit
//
//  The canonical AppleSMC wire struct, FourCC helpers and firmware result codes.
//
//  CRITICAL (PROMPT.md §4.2, pitfall #1): Swift does not lay out structs like C.
//  The explicit `padding: UInt16` placed before `result` is REQUIRED so that
//  `result` lands at byte offset 40. If these offsets drift, every SMC call
//  silently returns garbage. SMCKitTests asserts the whole layout.
//

import Foundation
import IOKit

// MARK: - FourCC

/// AppleSMC keys are FourCharCodes: 4 big-endian ASCII bytes packed into a UInt32.
/// Note that some keys legitimately contain spaces and are case sensitive
/// (`FS! ` has a trailing space; `F0Md` vs `F0md` differ by generation).
public enum FourCC {
    /// Packs a 4-character ASCII string into its big-endian UInt32 form.
    /// Returns nil unless the string is exactly 4 ASCII bytes.
    public static func encode(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    /// Unpacks a FourCC back to its 4-character ASCII form.
    /// Non-ASCII / non-printable codes are rendered as uppercase hex.
    public static func decode(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        if let string = String(bytes: bytes, encoding: .ascii),
           bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return string
        }
        return String(format: "%08X", value)
    }

    /// Trims the trailing NUL/space padding AppleSMC uses for `{fds` strings.
    public static func trim(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        while let last = slice.last, last == 0 || last == 0x20 { slice = slice.dropLast() }
        return String(bytes: slice, encoding: .ascii) ?? ""
    }
}

// MARK: - Firmware result codes

/// The SMC status byte returned inside the 80-byte struct.
///
/// `IOConnectCallStructMethod` returns `kIOReturnSuccess` even when the firmware
/// rejected the operation, so this byte MUST always be checked in addition to the
/// `kern_return_t` (PROMPT.md §4.1, pitfall #2).
public enum SMCSMCResult: UInt8, Sendable, Equatable {
    case success = 0x00
    case commCollision = 0x80
    case spuriousData = 0x81
    /// Firmware reject. This is what mode-key writes return while fans are locked
    /// in "system mode" (3) on M3/M4 — the signal to attempt the `Ftst` unlock.
    case badCommand = 0x82
    case badParameter = 0x83
    /// Key not found. The probe signal for optional keys (`Ftst`, lowercase `F0md`).
    case notFound = 0x84
    case notReadable = 0x85
    case notWritable = 0x86
    /// Key size mismatch. Observed on `F%dTg` writes where the value is sometimes
    /// applied anyway — read the key back before declaring failure.
    case sizeMismatch = 0x87
    case framingError = 0x88
    case badArgument = 0x89
    case unknown = 0xFF

    public init(code: UInt8) {
        self = SMCSMCResult(rawValue: code) ?? .unknown
    }

    /// True for the "key does not exist on this machine" answer.
    public var isNotFound: Bool { self == .notFound }

    public var localizedDescription: String {
        switch self {
        case .success: return "success"
        case .commCollision: return "communication collision"
        case .spuriousData: return "spurious data"
        case .badCommand: return "firmware refused the command (bad command)"
        case .badParameter: return "bad parameter"
        case .notFound: return "key not found"
        case .notReadable: return "key not readable"
        case .notWritable: return "key not writable"
        case .sizeMismatch: return "key size mismatch"
        case .framingError: return "framing error"
        case .badArgument: return "bad argument"
        case .unknown: return "unknown SMC error"
        }
    }
}

// MARK: - Command bytes

/// The selector values written into `data8` for `IOConnectCallStructMethod`.
public enum SMCCommand: UInt8, Sendable {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

/// IOKit selector for `IOConnectCallStructMethod`.
///
/// Both Stats and the macos-smc-fan RE project use selector 2 (connection type 0);
/// legacy Intel tools used 2 as well but opened with connection type 2. Both work.
public let kSMCKernelSelector: UInt32 = 2

// MARK: - The 80-byte wire struct

/// Mirrors the C `SMCKeyData_t` from `AppleSMC.kext`, with the Swift-specific
/// explicit padding that keeps the layout identical to the C definition.
///
/// Layout (asserted by `SMCTypesTests`):
/// ```
/// key        @0    FourCharCode (big-endian ASCII)
/// vers       @4    6 bytes
/// pLimitData @12   16 bytes
/// keyInfo    @28   dataSize@28, dataType@32, dataAttributes@36
/// padding    @38   UInt16  ← REQUIRED, Swift does not pad like C here
/// result     @40   SMC status byte
/// status     @41
/// data8      @42   command byte
/// data32     @44   index (for cmd 8)
/// bytes      @48   32-byte payload
/// total stride: 80
/// ```
public struct SMCKeyData_t: Sendable {
    public struct vers_t: Sendable {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
        public init() {}
    }

    public struct LimitData_t: Sendable {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
        public init() {}
    }

    public struct keyInfo_t: Sendable {
        public var dataSize: IOByteCount32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        public init() {}
    }

    public typealias SMCBytes_t = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    public var key: UInt32 = 0
    public var vers: vers_t = vers_t()
    public var pLimitData: LimitData_t = LimitData_t()
    public var keyInfo: keyInfo_t = keyInfo_t()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes_t = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}

    /// Decoded firmware status byte.
    public var smcResult: SMCSMCResult { SMCSMCResult(code: result) }

    /// The 4-character key name, as set by the caller.
    public var keyString: String { FourCC.decode(key) }

    /// The key's data type FourCC (only valid after a `readKeyInfo` call).
    public var dataTypeString: String { FourCC.decode(keyInfo.dataType) }

    /// The 32-byte payload as a plain array (offsets are stable; we always view
    /// all 32 bytes and let the codec slice what it needs).
    public var byteArray: [UInt8] {
        var copy = bytes
        return withUnsafeBytes(of: &copy) { Array($0) }
    }

    /// Copies up to 32 bytes into the payload, zero-filling the remainder.
    public mutating func setBytes(_ newBytes: [UInt8]) {
        var padded = Array(newBytes.prefix(32))
        if padded.count < 32 { padded.append(contentsOf: [UInt8](repeating: 0, count: 32 - padded.count)) }
        bytes = (
            padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11], padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19], padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27], padded[28], padded[29], padded[30], padded[31]
        )
    }
}

// MARK: - Key info / values

/// `readKeyInfo` (command 9) result for one key.
public struct SMCKeyInfo: Equatable, Sendable {
    public let key: String
    public let dataSize: UInt32
    public let dataType: String
    public let dataAttributes: UInt8

    public init(key: String, dataSize: UInt32, dataType: String, dataAttributes: UInt8) {
        self.key = key
        self.dataSize = dataSize
        self.dataType = dataType
        self.dataAttributes = dataAttributes
    }

    /// VirtualSMC `AppleSmc.h` attribute bits: bit7 = readable, bit6 = writable,
    /// bit0 = private-write. Fan keys carry 0xC0 / 0xC1.
    public var isReadable: Bool { dataAttributes & 0x80 != 0 }
    public var isWritable: Bool { dataAttributes & 0x40 != 0 }
    public var isPrivateWrite: Bool { dataAttributes & 0x01 != 0 }
}

/// A decoded SMC value. `raw` carries payloads whose data type has no codec here.
public enum SMCValue: Equatable, Sendable {
    case double(Double)
    case string(String)
    case raw([UInt8])

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .string: return nil
        case .raw(let bytes):
            // Best-effort: treat short payloads as a big-endian unsigned integer so
            // that an unknown but integer-typed key is still displayable.
            guard bytes.count <= 8 else { return nil }
            var value: UInt64 = 0
            for byte in bytes { value = (value << 8) | UInt64(byte) }
            return Double(value)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        // Deliberately nil: a numeric payload is not a string, and callers that ask
        // for one (fan names) must not silently receive "0.0".
        case .double, .raw: return nil
        }
    }

    public var rawBytes: [UInt8]? {
        switch self {
        case .raw(let bytes): return bytes
        case .double, .string: return nil
        }
    }
}

/// A full read result: the key, its metadata, the raw payload and the decoded value.
public struct SMCReading: Equatable, Sendable {
    public let key: String
    public let keyInfo: SMCKeyInfo
    public let bytes: [UInt8]
    public let value: SMCValue

    public init(key: String, keyInfo: SMCKeyInfo, bytes: [UInt8], value: SMCValue) {
        self.key = key
        self.keyInfo = keyInfo
        self.bytes = bytes
        self.value = value
    }

    public var dataType: String { keyInfo.dataType }
    public var doubleValue: Double? { value.doubleValue }
    public var stringValue: String? { value.stringValue }
}

/// Outcome of a write. `iokit` carries `kIOReturnNotPrivileged (0xe00002c2)` when
/// the caller is not root — the signal that writes must go through the helper.
public enum SMCWriteResult: Equatable, Sendable {
    case ok
    case smcResult(UInt8)
    case notConnected
    case encodingFailed(String)
    case iokit(kern_return_t)

    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }

    public var smcCode: SMCSMCResult? {
        if case .smcResult(let code) = self { return SMCSMCResult(code: code) }
        return nil
    }

    /// True when the failure is purely a privilege problem (not a firmware reject).
    public var isPermissionDenied: Bool {
        if case .iokit(let code) = self {
            return code == kIOReturnNotPrivileged || code == kIOReturnNotPermitted
        }
        return false
    }
}

/// Errors thrown by the high-level SMCKit API.
public enum SMCError: Error, Equatable, LocalizedError {
    case notConnected
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(selector: UInt32, code: kern_return_t)
    case badKey(String)
    case keyNotFound(String)
    case smc(String, SMCSMCResult)
    case notWritable(String)
    case decodeFailed(key: String, dataType: String, bytes: [UInt8])
    case encodeFailed(key: String, dataType: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to AppleSMC."
        case .serviceNotFound: return "AppleSMC service was not found in the IORegistry."
        case .openFailed(let code): return "IOServiceOpen failed (0x\(String(code, radix: 16)))."
        case .callFailed(let selector, let code):
            return "IOConnectCallStructMethod(selector \(selector)) failed (0x\(String(code, radix: 16)))."
        case .badKey(let key): return "\"\(key)\" is not a valid 4-character SMC key."
        case .keyNotFound(let key): return "SMC key \(key) does not exist on this Mac."
        case .smc(let key, let result): return "SMC \(key): \(result.localizedDescription)."
        case .notWritable(let key): return "SMC key \(key) is not writable."
        case .decodeFailed(let key, let type, let bytes):
            return "Could not decode \(key) as \(type) from \(bytes.count) byte(s)."
        case .encodeFailed(let key, let type): return "Could not encode a value for \(key) as \(type)."
        }
    }
}

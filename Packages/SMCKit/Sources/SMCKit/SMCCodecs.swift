//
//  SMCCodecs.swift
//  SMCKit
//
//  Value codecs keyed by the SMC `dataType` FourCC. Ported from the documented
//  formats in PROMPT.md §4.3 (cross-checked against Stats' `SMC/smc.swift`,
//  beltex/SMCKit and the VirtualSMC SDK).
//
//  Endianness rules that trip people up:
//    * `fpe2`, `ui16`, `ui32`, `sp78`, every `spXY`, `fp2e` → BIG-endian.
//    * `flt ` → NATIVE (little-endian on Apple Silicon and on modern Intel).
//

import Foundation

public enum SMCCodecs {

    /// Normalises a data-type FourCC for switching (drops the trailing space that
    /// several types carry: `ui8 `, `flt `, `hex_`).
    public static func normalize(_ dataType: String) -> String {
        dataType.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Decode

    /// Decodes a payload into an `SMCValue`.
    ///
    /// - Parameters:
    ///   - dataType: the key's `dataType` FourCC, e.g. `"flt "`, `"sp78"`, `"fpe2"`.
    ///   - bytes: the raw payload (at least `byteCount` bytes, 32 available).
    ///   - byteCount: the key's `dataSize`; drives how many bytes are significant.
    ///   - plausibleRange: optional sanity range used ONLY for `flt ` payloads —
    ///     a decoded float outside the range triggers a single byte-swapped retry
    ///     (guards against odd big-endian `flt ` reports on some T2-era Intel Macs).
    public static func decode(
        dataType: String,
        bytes: [UInt8],
        byteCount: Int,
        plausibleRange: ClosedRange<Double>? = nil
    ) throws -> SMCValue {
        let type = normalize(dataType)
        let count = byteCount > 0 ? byteCount : defaultSize(for: type)

        switch type {
        case "ui8", "flag", "hex_":
            guard let b0 = bytes.first else { throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes) }
            return .double(Double(b0))

        case "ui16", "si16":
            guard let raw = unsigned(bytes, count: 2) else {
                throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
            }
            if type == "si16" {
                return .double(Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw))))
            }
            return .double(Double(raw))

        case "ui32", "si32":
            guard let raw = unsigned(bytes, count: 4) else {
                throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
            }
            if type == "si32" {
                return .double(Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))))
            }
            return .double(Double(raw))

        case "ui64":
            guard let raw = unsigned(bytes, count: 8) else {
                throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
            }
            return .double(Double(raw))

        case "fpe2":
            guard bytes.count >= 2 else {
                throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
            }
            let b0 = UInt16(bytes[0]), b1 = UInt16(bytes[1])
            let whole = (b0 << 6) | (b1 >> 2)
            let fraction = Double(b1 & 0x03) / 4.0
            return .double(Double(whole) + fraction)

        case "fp2e":
            guard let raw = unsigned(bytes, count: 2) else {
                throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
            }
            return .double(Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw))) / 16384.0)

        case "flt":
            return .double(decodeFloat(bytes: bytes, plausibleRange: plausibleRange))

        case "{fds":
            // Fan description struct: 16 bytes total, an ASCII name at bytes[4...15].
            let nameBytes = bytes.count >= 16 ? Array(bytes[4..<16]) : Array(bytes.dropFirst(min(4, bytes.count)))
            return .string(FourCC.trim(nameBytes))

        default:
            // `spXY` = signed X.Y fixed point where X + Y = 15.
            if type.hasPrefix("sp"), type.count == 4,
               let x = hexValue(type, at: 2), let y = hexValue(type, at: 3), x + y == 15 {
                guard let raw = unsigned(bytes, count: 2) else {
                    throw SMCError.decodeFailed(key: "", dataType: dataType, bytes: bytes)
                }
                let signed = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
                return .double(signed / pow(2.0, Double(y)))
            }
            // Unknown type: hand back the significant bytes so callers can still show
            // something (and so the "unknown sensors" UI has a value).
            return .raw(Array(bytes.prefix(max(1, min(count, 32)))))
        }
    }

    // MARK: - Encode

    /// Encodes a numeric value for a key, producing exactly `byteCount` bytes
    /// (zero padded) — the SMC expects the payload sized to the key.
    public static func encode(
        double value: Double,
        dataType: String,
        byteCount: Int
    ) throws -> [UInt8] {
        let type = normalize(dataType)
        let count = byteCount > 0 ? byteCount : defaultSize(for: type)

        switch type {
        case "ui8", "flag", "hex_":
            return [UInt8(clamping: Int(value.rounded()))] + zeros(count - 1)

        case "ui16":
            return bigEndian(UInt16(clamping: Int(value.rounded())), count: count)

        case "si16":
            return bigEndian(UInt16(bitPattern: Int16(clamping: Int(value.rounded()))), count: count)

        case "ui32":
            return bigEndian(UInt32(clamping: Int(value.rounded())), count: count)

        case "si32":
            return bigEndian(UInt32(bitPattern: Int32(clamping: Int(value.rounded()))), count: count)

        case "ui64":
            return bigEndian(UInt64(clamping: Int64(value.rounded())), count: count)

        case "fpe2":
            let rpm = UInt16(clamping: Int(value.rounded()))
            return [UInt8((rpm >> 6) & 0xFF), UInt8((rpm << 2) & 0xFF)] + zeros(count - 2)

        case "fp2e":
            let raw = UInt16(bitPattern: Int16(clamping: Int((value * 16384.0).rounded())))
            return bigEndian(raw, count: count)

        case "flt":
            // Native byte order, which is little-endian on every Mac that runs this.
            var bitPattern = Float(value).bitPattern
            let encoded = withUnsafeBytes(of: &bitPattern) { Array($0.prefix(count)) }
            return encoded + zeros(count - encoded.count)

        case "{fds":
            var payload = Array("    ".utf8)            // 4-byte struct header
            payload += Array(value.description.utf8.prefix(12))
            return payload + zeros(max(count, 16) - payload.count)

        default:
            if type.hasPrefix("sp"), type.count == 4,
               let x = hexValue(type, at: 2), let y = hexValue(type, at: 3), x + y == 15 {
                let scaled = (value * pow(2.0, Double(y))).rounded()
                let raw = UInt16(bitPattern: Int16(clamping: Int(scaled)))
                return bigEndian(raw, count: count)
            }
            throw SMCError.encodeFailed(key: "", dataType: dataType)
        }
    }

    /// Encodes an `SMCValue` (string values are only valid for `{fds`).
    public static func encode(_ value: SMCValue, dataType: String, byteCount: Int) throws -> [UInt8] {
        switch value {
        case .double(let d):
            return try encode(double: d, dataType: dataType, byteCount: byteCount)
        case .string(let s):
            guard normalize(dataType).hasPrefix("{fds") else {
                throw SMCError.encodeFailed(key: "", dataType: dataType)
            }
            var payload = Array("    ".utf8)            // 4-byte struct header
            payload += Array(s.utf8.prefix(12))
            if byteCount > payload.count { payload += zeros(byteCount - payload.count) }
            return Array(payload.prefix(max(byteCount, 16)))
        case .raw(let bytes):
            return bytes + zeros(byteCount - bytes.count)
        }
    }

    /// The canonical byte width for a data type (used when `dataSize` reads as 0).
    public static func defaultSize(for type: String) -> Int {
        switch normalize(type) {
        case "ui8", "flag", "hex_": return 1
        case "ui16", "si16", "sp78", "fpe2", "fp2e": return 2
        case "ui32", "si32", "flt": return 4
        case "ui64": return 8
        case "{fds": return 16
        default:
            if normalize(type).hasPrefix("sp") { return 2 }
            return 4
        }
    }

    // MARK: - Float helpers

    /// Decodes an `flt ` payload, native (little-endian) first, with the
    /// documented byte-swap fallback when the result is implausible.
    public static func decodeFloat(bytes: [UInt8], plausibleRange: ClosedRange<Double>? = nil) -> Double {
        guard bytes.count >= 4 else { return 0 }
        let little = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let nativeDouble = Double(Float(bitPattern: little))

        if isPlausibleFloat(nativeDouble, in: plausibleRange) { return nativeDouble }

        // Retry byte-swapped once — some T2-era Intel machines have been seen
        // reporting `flt ` in the opposite byte order.
        let swappedDouble = Double(Float(bitPattern: little.byteSwapped))
        if isPlausibleFloat(swappedDouble, in: plausibleRange) { return swappedDouble }

        return nativeDouble
    }

    /// A decoded float is plausible when it is finite, not a denormal (the signature
    /// of a byte-swapped payload) and — when a range is supplied — inside that range.
    private static func isPlausibleFloat(_ value: Double, in range: ClosedRange<Double>?) -> Bool {
        guard value.isFinite else { return false }
        if value != 0, abs(value) < Double(Float.leastNormalMagnitude) { return false }
        if let range { return range.contains(value) }
        return true
    }

    // MARK: - Private

    private static func hexValue(_ string: String, at offset: Int) -> Int? {
        let characters = Array(string)
        guard offset < characters.count else { return nil }
        return Int(String(characters[offset]), radix: 16)
    }

    private static func unsigned(_ bytes: [UInt8], count: Int) -> UInt64? {
        guard bytes.count >= count, count > 0, count <= 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<count { value = (value << 8) | UInt64(bytes[index]) }
        return value
    }

    private static func bigEndian(_ value: UInt16, count: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] + zeros(count - 2)
    }

    private static func bigEndian(_ value: UInt32, count: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ] + zeros(count - 4)
    }

    private static func bigEndian(_ value: UInt64, count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        return bytes + zeros(count - 8)
    }

    private static func zeros(_ count: Int) -> [UInt8] {
        count > 0 ? [UInt8](repeating: 0, count: count) : []
    }
}

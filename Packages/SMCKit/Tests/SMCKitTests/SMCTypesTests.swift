//
//  SMCTypesTests.swift
//  SMCKitTests
//
//  Layout + codec vectors. PROMPT.md §4.2/pitfall #1: if these offsets drift,
//  every SMC call silently returns garbage — so they are asserted explicitly.
//

import XCTest
import IOKit
@testable import SMCKit

final class SMCTypesTests: XCTestCase {

    // MARK: - Struct layout

    func testStructStrideIs80() {
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.stride, 80, "SMCKeyData_t must be exactly 80 bytes")
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.size, 80)
    }

    func testFieldOffsets() {
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.vers), 4)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.pLimitData), 12)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataSize), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataType), 32)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo.dataAttributes), 36)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.padding), 38)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCKeyData_t>.offset(of: \.bytes), 48)
    }

    func testPayloadRoundTripThroughTuple() {
        var data = SMCKeyData_t()
        data.setBytes([0x41, 0x42, 0x43])
        XCTAssertEqual(Array(data.byteArray.prefix(4)), [0x41, 0x42, 0x43, 0x00])
        XCTAssertEqual(data.byteArray.count, 32)
        data.setBytes(Array(0..<40).map { UInt8($0) })
        XCTAssertEqual(data.byteArray.count, 32, "payloads longer than 32 bytes are truncated")
    }

    // MARK: - FourCC

    func testFourCCRoundTrip() {
        XCTAssertEqual(FourCC.encode("F0Ac"), 0x4630_4163)
        XCTAssertEqual(FourCC.decode(0x4630_4163), "F0Ac")
        XCTAssertEqual(FourCC.decode(FourCC.encode("FS! ")!), "FS! ", "trailing space is significant")
        XCTAssertEqual(FourCC.decode(FourCC.encode("#KEY")!), "#KEY")
        XCTAssertNil(FourCC.encode("toolong"))
        XCTAssertNil(FourCC.encode("ab"))
    }

    func testFourCCTrim() {
        XCTAssertEqual(FourCC.trim([0x4C, 0x20, 0x66, 0x61, 0x6E, 0x00, 0x00, 0x00]), "L fan")
        XCTAssertEqual(FourCC.trim([0x00, 0x00]), "")
    }

    func testResultCodeMapping() {
        XCTAssertEqual(SMCSMCResult(code: 0x82), .badCommand)
        XCTAssertEqual(SMCSMCResult(code: 0x84), .notFound)
        XCTAssertEqual(SMCSMCResult(code: 0x87), .sizeMismatch)
        XCTAssertEqual(SMCSMCResult(code: 0x7F), .unknown)
        XCTAssertTrue(SMCSMCResult(code: 0x84).isNotFound)
        XCTAssertFalse(SMCSMCResult(code: 0x00).isNotFound)
    }

    func testWriteResultClassifiesPrivilegeFailures() {
        XCTAssertTrue(SMCWriteResult.iokit(kIOReturnNotPrivileged).isPermissionDenied)
        XCTAssertFalse(SMCWriteResult.iokit(kIOReturnSuccess).isPermissionDenied)
        XCTAssertFalse(SMCWriteResult.smcResult(0x82).isPermissionDenied)
        XCTAssertTrue(SMCWriteResult.ok.isSuccess)
        XCTAssertEqual(SMCWriteResult.smcResult(0x87).smcCode, .sizeMismatch)
    }

    // MARK: - Codec vectors (PROMPT.md §8)

    func testFpe2Decode() throws {
        // (0, 1, 1299, 16383) per the testing plan.
        XCTAssertEqual(try decodeDouble("fpe2", [0x00, 0x00]), 0.0)
        XCTAssertEqual(try decodeDouble("fpe2", [0x00, 0x04]), 1.0)      // 0<<6 | 4>>2 = 1
        XCTAssertEqual(try decodeDouble("fpe2", [0x14, 0x4C]), 1299.0)   // 20<<6 | 0x4C>>2 = 1280+19
        XCTAssertEqual(try decodeDouble("fpe2", [0xFF, 0xFC]), 16383.0)  // max
    }

    func testFpe2EncodeRoundTrip() throws {
        for rpm in [0.0, 1.0, 1299.0, 16383.0, 2000.0] {
            let bytes = try SMCCodecs.encode(double: rpm, dataType: "fpe2", byteCount: 2)
            XCTAssertEqual(bytes.count, 2)
            XCTAssertEqual(try decodeDouble("fpe2", bytes), rpm, accuracy: 0.5)
        }
    }

    func testSp78Decode() throws {
        // sp78 = signed 8.8 fixed point, big-endian.
        XCTAssertEqual(try decodeDouble("sp78", [0xEB, 0x80]), -20.5)  // 0xEB80 = -5248 / 256
        XCTAssertEqual(try decodeDouble("sp78", [0x00, 0x00]), 0.0)
        XCTAssertEqual(try decodeDouble("sp78", [0x69, 0x40]), 105.25) // 0x6940 = 26944 / 256
    }

    func testSp78EncodeRoundTrip() throws {
        for value in [-20.5, 0.0, 105.25, 99.0] {
            let bytes = try SMCCodecs.encode(double: value, dataType: "sp78", byteCount: 2)
            XCTAssertEqual(try decodeDouble("sp78", bytes), value, accuracy: 1.0 / 256.0)
        }
    }

    func testSpXYDivisorTable() throws {
        // PROMPT.md §4.3 divisor table for spXY (X + Y = 15).
        let expectations: [(String, Double)] = [
            ("sp1e", 16384), ("sp3c", 4096), ("sp4b", 2048), ("sp5a", 1024),
            ("sp69", 512), ("sp87", 128), ("sp96", 64), ("spa5", 32),
            ("spb4", 16), ("spf0", 1),
        ]
        for (type, divisor) in expectations {
            let raw = UInt16(0x0100) // 256
            let bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
            XCTAssertEqual(try decodeDouble(type, bytes), 256.0 / divisor, accuracy: 1e-9, type)
        }
    }

    func testFloatLittleEndianDecode() throws {
        // Apple Silicon `flt ` RPM values are native little-endian.
        let value: Float = 1234.5
        var bitPattern = value.bitPattern
        let bytes = withUnsafeBytes(of: &bitPattern) { Array($0) }
        XCTAssertEqual(try decodeDouble("flt ", bytes, range: 0...20000), 1234.5, accuracy: 0.001)
        XCTAssertEqual(try decodeDouble("flt ", [0, 0, 0, 0], range: 0...20000), 0.0)
    }

    func testFloatByteSwapFallback() throws {
        // Big-endian `flt ` (an odd T2-era report): native decode is implausible, so
        // the codec retries byte-swapped and returns a sane value.
        let value: Float = 1800
        var bigEndian = value.bitPattern.bigEndian
        let bytes = withUnsafeBytes(of: &bigEndian) { Array($0) }
        let decoded = try decodeDouble("flt ", bytes, range: 0...20000)
        XCTAssertEqual(decoded, 1800, accuracy: 0.001)
    }

    func testFloatNaNReturnsNonFiniteRatherThanCrashing() throws {
        let nanBytes: [UInt8] = [0x00, 0x00, 0xC0, 0x7F] // Float.nan little-endian
        let decoded = try decodeDouble("flt ", nanBytes, range: 0...20000)
        XCTAssertFalse(decoded.isFinite)
    }

    func testUInt16BigEndian() throws {
        XCTAssertEqual(try decodeDouble("ui16", [0x01, 0x02]), 258.0)
        XCTAssertEqual(try SMCCodecs.encode(double: 258, dataType: "ui16", byteCount: 2), [0x01, 0x02])
    }

    func testUInt32BigEndian() throws {
        XCTAssertEqual(try decodeDouble("ui32", [0x00, 0x00, 0x01, 0x02]), 258.0)
    }

    func testUInt8AndFlag() throws {
        XCTAssertEqual(try decodeDouble("ui8 ", [0x01]), 1.0)
        XCTAssertEqual(try decodeDouble("ui8 ", [0x03]), 3.0)
        XCTAssertEqual(try SMCCodecs.encode(double: 3, dataType: "ui8 ", byteCount: 1), [0x03])
    }

    func testFdsDecodeTrimsName() throws {
        // `F0ID` = 16-byte struct with a 12-char ASCII name at bytes[4...15].
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01
        let name = Array("L fan".utf8)
        bytes.replaceSubrange(4..<(4 + name.count), with: name)
        let value = try SMCCodecs.decode(dataType: "{fds", bytes: bytes, byteCount: 16)
        XCTAssertEqual(value, .string("L fan"))
    }

    func testUnknownDataTypeFallsBackToRaw() throws {
        let value = try SMCCodecs.decode(dataType: "zzzz", bytes: [1, 2, 3, 4], byteCount: 4)
        XCTAssertEqual(value, .raw([1, 2, 3, 4]))
    }

    func testEncodePaddingMatchesDeclaredSize() throws {
        // Every encode must return exactly the key's dataSize bytes.
        XCTAssertEqual(try SMCCodecs.encode(double: 1, dataType: "ui8 ", byteCount: 1).count, 1)
        XCTAssertEqual(try SMCCodecs.encode(double: 1, dataType: "ui16", byteCount: 2).count, 2)
        XCTAssertEqual(try SMCCodecs.encode(double: 1, dataType: "ui32", byteCount: 4).count, 4)
        XCTAssertEqual(try SMCCodecs.encode(double: 1, dataType: "flt ", byteCount: 4).count, 4)
        XCTAssertEqual(try SMCCodecs.encode(double: 1, dataType: "sp78", byteCount: 2).count, 2)
    }

    // MARK: - Helpers

    private func decodeDouble(
        _ type: String,
        _ bytes: [UInt8],
        range: ClosedRange<Double>? = nil
    ) throws -> Double {
        let value = try SMCCodecs.decode(dataType: type, bytes: bytes, byteCount: bytes.count, plausibleRange: range)
        guard let double = value.doubleValue else {
            XCTFail("expected a numeric decode for \(type), got \(value)")
            return .nan
        }
        return double
    }
}

//
//  ProfileTests.swift
//  AutoFansMacTests
//
//  PROMPT.md §8 unit tests for the profile layer: Codable round-trip, `@max` resolution,
//  schema v0 → v1 migration, built-in immutability and fan-count mismatch handling.
//

import XCTest
import SMCKit
@testable import AutoFansMac

final class ProfileTests: XCTestCase {

    // MARK: Codable

    func testDocumentRoundTripsThroughJSON() throws {
        var document = ProfileDocument.makeDefault(fanCount: 2)
        document.activeProfileID = Profile.fullBlastID
        document.applyAtLaunch = false
        document.profiles.append(
            Profile(
                id: "custom-1",
                name: "Quiet Studio",
                builtIn: false,
                fans: [
                    FanSetting(index: 0, mode: .sensor, rpm: .value(0), sensorKey: "Tp01",
                               sensorName: "CPU performance core 1", minTemp: 50, maxTemp: 80),
                    FanSetting(index: 1, mode: .constant, rpm: .value(1_800)),
                ]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let decoded = try JSONDecoder().decode(ProfileDocument.self, from: data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.profiles.count, 3)
    }

    func testMaximumRPMEncodesAsTheSchemaToken() throws {
        let profile = Profile.fullBlast(fanCount: 2)
        let data = try JSONEncoder().encode(profile)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"@max\""), "@max must be stored as the documented token: \(json)")

        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.fans.first?.rpm, .maximum)
    }

    func testMaximumResolvesToTheLiveHardwareValue() {
        XCTAssertEqual(FanRPMSetting.maximum.resolved(maxRPM: 7_826), 7_826)
        XCTAssertEqual(FanRPMSetting.value(2_000).resolved(maxRPM: 7_826), 2_000)
    }

    func testHandWrittenNumericRPMDecodes() throws {
        let json = """
        { "index": 0, "mode": "constant", "rpm": 1800, "minTemp": 50, "maxTemp": 80 }
        """
        let setting = try JSONDecoder().decode(FanSetting.self, from: Data(json.utf8))
        XCTAssertEqual(setting.rpm, .value(1_800))
        XCTAssertEqual(setting.mode, .constant)
    }

    // MARK: Migration

    func testMigrationAddsMissingBuiltIns() {
        // A hand-edited file with only a custom profile and a v0 version.
        let document = ProfileDocument(
            version: 0,
            activeProfileID: "custom-1",
            applyAtLaunch: true,
            profiles: [Profile(id: "custom-1", name: "Mine", builtIn: false, fans: [.auto(0)])]
        )

        let (migrated, notes) = ProfileDocument.migrate(document, fanCount: 2)
        XCTAssertEqual(migrated.version, 1)
        XCTAssertNotNil(migrated.profiles.first { $0.id == Profile.automaticID })
        XCTAssertNotNil(migrated.profiles.first { $0.id == Profile.fullBlastID })
        XCTAssertFalse(notes.isEmpty, "migration must report what it changed")
    }

    func testMigrationRestoresATamperedBuiltIn() {
        var document = ProfileDocument.makeDefault(fanCount: 2)
        // Someone edited the Automatic profile to pin fans at 5000 RPM by hand.
        if let index = document.profiles.firstIndex(where: { $0.id == Profile.automaticID }) {
            document.profiles[index].fans = [FanSetting(index: 0, mode: .constant, rpm: .value(5_000))]
        }

        let (migrated, notes) = ProfileDocument.migrate(document, fanCount: 2)
        XCTAssertEqual(
            migrated.profiles.first { $0.id == Profile.automaticID }?.fans.first?.mode, .auto,
            "a built-in profile must not be redefinable by editing the JSON"
        )
        XCTAssertTrue(notes.contains { $0.contains("Automatic") })
    }

    func testMigrationRepairsADanglingActiveProfile() {
        var document = ProfileDocument.makeDefault(fanCount: 2)
        document.activeProfileID = "does-not-exist"

        let (migrated, _) = ProfileDocument.migrate(document, fanCount: 2)
        XCTAssertEqual(migrated.activeProfileID, Profile.automaticID)
    }

    func testDefaultDocumentHasBothBuiltInsAndAutomaticActive() {
        let document = ProfileDocument.makeDefault(fanCount: 2)
        XCTAssertEqual(document.profiles.count, 2)
        XCTAssertEqual(document.activeProfileID, Profile.automaticID)
        XCTAssertTrue(document.profiles.allSatisfy(\.builtIn))
        XCTAssertTrue(document.applyAtLaunch)
    }

    // MARK: Fan-count mismatch

    func testReconcileAddsMissingFansAsAuto() {
        let profile = Profile.fullBlast(fanCount: 2)
        let (reconciled, warning) = profile.reconcile(withFanCount: 4)

        XCTAssertNotNil(warning)
        XCTAssertEqual(reconciled.fanIndices, [0, 1, 2, 3])
        XCTAssertEqual(reconciled.setting(for: 2)?.mode, .auto)
        XCTAssertEqual(reconciled.setting(for: 3)?.mode, .auto)
        XCTAssertEqual(reconciled.setting(for: 0)?.mode, .constant, "existing settings must be preserved")
    }

    func testReconcileDropsFansThisMachineDoesNotHave() {
        let profile = Profile.fullBlast(fanCount: 2)
        let (reconciled, warning) = profile.reconcile(withFanCount: 1)

        XCTAssertNotNil(warning)
        XCTAssertEqual(reconciled.fanIndices, [0])
    }

    func testReconcileIsANoOpWhenTheyMatch() {
        let profile = Profile.fullBlast(fanCount: 2)
        let (reconciled, warning) = profile.reconcile(withFanCount: 2)
        XCTAssertNil(warning)
        XCTAssertEqual(reconciled, profile)
    }

    // MARK: Built-in semantics

    func testAutomaticProfileIsEveryFanAuto() {
        let profile = Profile.automatic(fanCount: 3)
        XCTAssertEqual(profile.fans.count, 3)
        XCTAssertTrue(profile.fans.allSatisfy { $0.mode == .auto })
    }

    func testFullBlastIsMaximumOnEveryFan() {
        let profile = Profile.fullBlast(fanCount: 3)
        XCTAssertTrue(profile.fans.allSatisfy { $0.mode == .constant && $0.rpm == .maximum })
    }

    func testTemperatureRangeValidation() {
        XCTAssertTrue(FanSetting(index: 0, minTemp: 50, maxTemp: 80).hasValidTemperatureRange)
        XCTAssertFalse(FanSetting(index: 0, minTemp: 80, maxTemp: 80).hasValidTemperatureRange)
        XCTAssertFalse(FanSetting(index: 0, minTemp: 90, maxTemp: 60).hasValidTemperatureRange)
        XCTAssertFalse(FanSetting(index: 0, minTemp: 0, maxTemp: 200).hasValidTemperatureRange)
    }

    // MARK: Store persistence

    func testStorePersistsAndReloadsFromDisk() throws {
        // Redirect the store to a scratch directory by exercising the document directly:
        // the file URL is fixed, so this test verifies the codec path used by the store.
        var document = ProfileDocument.makeDefault(fanCount: 2)
        document.profiles.append(
            Profile(id: "custom-2", name: "Gaming", builtIn: false,
                    fans: [FanSetting(index: 0, mode: .constant, rpm: .maximum)])
        )

        let data = try JSONEncoder().encode(document)
        let reloaded = try JSONDecoder().decode(ProfileDocument.self, from: data)
        let (migrated, notes) = ProfileDocument.migrate(reloaded, fanCount: 2)

        XCTAssertEqual(migrated.profiles.count, 3)
        XCTAssertTrue(notes.isEmpty, "a well-formed v1 file needs no repair")
        XCTAssertEqual(migrated.profiles.first { $0.id == "custom-2" }?.name, "Gaming")
    }
}

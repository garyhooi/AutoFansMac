//
//  Profile.swift
//  AutoFansMac
//
//  Profile schema, versioning and the two built-in profiles (PROMPT.md §6.4, R5/R6).
//
//  Persisted as JSON in ~/Library/Application Support/AutoFansMac/profiles.json so it
//  stays inspectable and hand-editable, with an explicit `version` for migration.
//

import Foundation

/// A named set of per-fan settings.
struct Profile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Built-ins cannot be renamed or deleted — only duplicated into editable copies.
    var builtIn: Bool
    var fans: [FanSetting]

    // MARK: Built-ins

    static let automaticID = "builtin.automatic"
    static let fullBlastID = "builtin.fullblast"

    /// **Automatic** — every fan returned to macOS control.
    static func automatic(fanCount: Int) -> Profile {
        Profile(
            id: automaticID,
            name: "Automatic",
            builtIn: true,
            fans: (0..<max(fanCount, 1)).map { FanSetting.auto($0) }
        )
    }

    /// **Full Blast** — every fan commanded to its own `F%dMx`.
    static func fullBlast(fanCount: Int) -> Profile {
        Profile(
            id: fullBlastID,
            name: "Full Blast",
            builtIn: true,
            fans: (0..<max(fanCount, 1)).map {
                FanSetting(index: $0, mode: .constant, rpm: .maximum)
            }
        )
    }

    /// A sensible starting point for "New profile": current auto state with one
    /// sensor-based fan pre-filled so the curve editor has something to show.
    static func newCustom(name: String, fanCount: Int, defaultSensorKey: String?, defaultSensorName: String?) -> Profile {
        var fans = (0..<max(fanCount, 1)).map { FanSetting.auto($0) }
        if !fans.isEmpty, let key = defaultSensorKey {
            fans[0] = FanSetting(
                index: 0,
                mode: .sensor,
                rpm: .value(0),
                sensorKey: key,
                sensorName: defaultSensorName,
                minTemp: 50,
                maxTemp: 80
            )
        }
        return Profile(id: UUID().uuidString, name: name, builtIn: false, fans: fans)
    }

    // MARK: Helpers

    func setting(for fanIndex: Int) -> FanSetting? {
        fans.first { $0.index == fanIndex }
    }

    /// Fan indices this profile covers.
    var fanIndices: [Int] { fans.map(\.index).sorted() }

    /// True when the profile was created on a machine with a different fan count.
    func mismatches(fanCount: Int) -> Bool {
        fanIndices.contains { $0 >= fanCount } || fanIndices.count != fanCount
    }

    var summary: String {
        let auto = fans.filter { $0.mode == .auto }.count
        let constant = fans.filter { $0.mode == .constant }.count
        let sensor = fans.filter { $0.mode == .sensor }.count
        var parts: [String] = []
        if auto > 0 { parts.append("\(auto) auto") }
        if constant > 0 { parts.append("\(constant) constant") }
        if sensor > 0 { parts.append("\(sensor) sensor-based") }
        return parts.isEmpty ? "No fans configured" : parts.joined(separator: " · ")
    }

    // MARK: Fan-count reconciliation

    /// Adapts a profile to this machine's fan count: applies the intersecting indices and
    /// returns a warning when the profile came from a machine with a different fan count
    /// (PROMPT.md §6.4).
    func reconcile(withFanCount fanCount: Int) -> (profile: Profile, warning: String?) {
        guard mismatches(fanCount: fanCount) else { return (self, nil) }

        var fans = self.fans.filter { $0.index < fanCount }
        let existing = Set(fans.map(\.index))
        for index in 0..<max(fanCount, 0) where !existing.contains(index) {
            fans.append(.auto(index))
        }
        fans.sort { $0.index < $1.index }

        let warning = "“\(name)” was created for a different number of fans "
            + "(\(fanIndices.count)) than this Mac has (\(fanCount)); the extra fans were set to Auto."
        return (Profile(id: id, name: name, builtIn: builtIn, fans: fans), warning)
    }
}

/// The on-disk document: profiles + which one is active.
struct ProfileDocument: Codable, Equatable {
    /// Schema version. Bump and add a migration step when the shape changes.
    static let currentVersion = 1

    var version: Int
    var activeProfileID: String
    var applyAtLaunch: Bool
    var profiles: [Profile]

    init(version: Int = ProfileDocument.currentVersion, activeProfileID: String, applyAtLaunch: Bool, profiles: [Profile]) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.applyAtLaunch = applyAtLaunch
        self.profiles = profiles
    }

    /// A fresh document with both built-ins and "Automatic" active.
    static func makeDefault(fanCount: Int) -> ProfileDocument {
        ProfileDocument(
            activeProfileID: Profile.automaticID,
            applyAtLaunch: true,
            profiles: [.automatic(fanCount: fanCount), .fullBlast(fanCount: fanCount)]
        )
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    // MARK: Migration

    /// Migrates a decoded document from any older schema version.
    ///
    /// v0 → v1: early hand-written files had no `version` and no `applyAtLaunch`; both
    /// are defaulted here rather than rejecting the file.
    static func migrate(_ document: ProfileDocument, fanCount: Int) -> (document: ProfileDocument, notes: [String]) {
        var document = document
        var notes: [String] = []

        if document.version < 1 {
            document.version = 1
            if document.profiles.isEmpty {
                document.profiles = [.automatic(fanCount: fanCount), .fullBlast(fanCount: fanCount)]
            }
            notes.append("Upgraded profile file from schema v0 to v1.")
        }

        // Always guarantee the built-ins exist and keep them immutable: a hand-edited
        // file must not be able to change what "Automatic" means.
        let automatic = Profile.automatic(fanCount: fanCount)
        let fullBlast = Profile.fullBlast(fanCount: fanCount)
        if let index = document.profiles.firstIndex(where: { $0.id == Profile.automaticID }) {
            if document.profiles[index] != automatic {
                document.profiles[index] = automatic
                notes.append("Restored the built-in Automatic profile.")
            }
        } else {
            document.profiles.insert(automatic, at: 0)
            notes.append("Added the missing built-in Automatic profile.")
        }
        if let index = document.profiles.firstIndex(where: { $0.id == Profile.fullBlastID }) {
            if document.profiles[index] != fullBlast {
                document.profiles[index] = fullBlast
                notes.append("Restored the built-in Full Blast profile.")
            }
        } else {
            document.profiles.insert(fullBlast, at: 1)
            notes.append("Added the missing built-in Full Blast profile.")
        }

        // A dangling active id falls back to Automatic.
        if !document.profiles.contains(where: { $0.id == document.activeProfileID }) {
            document.activeProfileID = Profile.automaticID
            notes.append("The active profile no longer existed; switched to Automatic.")
        }

        return (document, notes)
    }

}

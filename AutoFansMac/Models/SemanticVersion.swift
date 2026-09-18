//
//  SemanticVersion.swift
//  AutoFansMac
//
//  Dotted-version comparison for the update check.
//
//  Release tags are whatever the author typed — "v1.0.0", "1.0", "1.0.1" — while the app's
//  own version comes from `MARKETING_VERSION`, which has no reason to use the same number of
//  components. Comparison is therefore numeric and zero-padded component by component, never
//  lexicographic: as strings "1.9.9" > "1.10.0", and a string compare would tell the user
//  that their newer release is older than what they are running.
//

import Foundation

/// A version parsed from its dotted, human-written form.
struct SemanticVersion: Comparable, Equatable {

    /// Numeric components, most significant first. Trailing zeroes are dropped so that
    /// "1.0" and "1.0.0" are literally the same value — `Comparable` requires `==` to agree
    /// with `<`, and a padded compare with an unpadded equality would not.
    let components: [Int]

    /// Reads "1.0.0", "v1.0.1", "2.0-rc1", "1.10", "1.0.0 (42)".
    ///
    /// Returns nil when there is no leading number to read; the caller then falls back to
    /// plain inequality instead of pretending to know the order.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        // Everything from the first "-" or "+" on is a pre-release/build suffix. The
        // releases endpoint already excludes drafts and pre-releases, so it never matters.
        let core = text.prefix { $0 != "-" && $0 != "+" && $0 != " " }

        var numbers: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part) else { break }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }

        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

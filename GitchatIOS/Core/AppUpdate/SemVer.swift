import Foundation

/// Lightweight semver comparator.
///
/// `String.compare(_:options:.numeric)` is not enough for version
/// strings — it compares lexicographically with per-component numeric
/// ordering, which is close but breaks on edge cases like `"1.10.0"`
/// vs `"1.2.0"` once pre-release suffixes show up.
/// This parses `major.minor.patch` (extra components treated as 0)
/// and compares component-wise. Non-numeric prefixes like `"v1.2.3"`
/// are tolerated.
struct SemVer: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse a version string. Returns nil when the leading token
    /// isn't numeric at all (e.g. "next") — callers decide how to
    /// treat that. Missing components default to 0 so `"1.4"` parses
    /// as `1.4.0`.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = trimmed
            .split(separator: ".", omittingEmptySubsequences: false)
            .prefix(3)
        let ints = parts.map { part -> Int? in
            let digits = part.prefix { $0.isNumber }
            return Int(digits)
        }
        guard let first = ints.first, let maj = first else { return nil }
        self.major = maj
        self.minor = ints.count > 1 ? (ints[1] ?? 0) : 0
        self.patch = ints.count > 2 ? (ints[2] ?? 0) : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

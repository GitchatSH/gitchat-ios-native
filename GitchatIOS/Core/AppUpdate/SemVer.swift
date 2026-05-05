import Foundation

struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Lenient parser:
    /// - Strips a leading `v` (e.g., `"v1.2.3"` → `1.2.3`).
    /// - Drops any `-prerelease` and `+build` suffixes.
    /// - Tolerates 1- or 2-component inputs (defaults missing components to 0).
    ///
    /// Strict on present components: returns `nil` whenever a component is
    /// present but non-numeric (e.g., `"1.x.0"`, `"1..3"`). For an update
    /// gate, fail-loud is preferred over fail-silent — silently coercing a
    /// malformed version to zero could suppress a prompt the user should see.
    init?(_ raw: String) {
        var trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        if let dash = trimmed.firstIndex(of: "-") { trimmed = String(trimmed[..<dash]) }
        if let plus = trimmed.firstIndex(of: "+") { trimmed = String(trimmed[..<plus]) }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor: Int
        if parts.count > 1 {
            guard let parsed = Int(parts[1]) else { return nil }
            minor = parsed
        } else {
            minor = 0
        }
        let patch: Int
        if parts.count > 2 {
            guard let parsed = Int(parts[2]) else { return nil }
            patch = parsed
        } else {
            patch = 0
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

import Foundation

struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Lenient parser: strips a leading `v`, drops any `-prerelease` or
    /// `+build` suffix, and tolerates 1- or 2-component inputs by defaulting
    /// missing components to 0. Returns `nil` only when the major component
    /// is absent or non-numeric.
    init?(_ raw: String) {
        var trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        if let dash = trimmed.firstIndex(of: "-") { trimmed = String(trimmed[..<dash]) }
        if let plus = trimmed.firstIndex(of: "+") { trimmed = String(trimmed[..<plus]) }

        let parts = trimmed.split(separator: ".").map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
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

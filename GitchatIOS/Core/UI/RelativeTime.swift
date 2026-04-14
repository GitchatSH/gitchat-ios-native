import Foundation

enum RelativeTime {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoNoFractional.date(from: s)
    }

    static func format(_ s: String?) -> String {
        guard let date = parse(s) else { return "" }
        let delta = -date.timeIntervalSinceNow
        if delta < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

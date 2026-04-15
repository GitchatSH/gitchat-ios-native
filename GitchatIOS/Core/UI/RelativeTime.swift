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

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        return f
    }()

    /// Compact stamp suited for chat list rows: today → HH:mm,
    /// yesterday → "Yesterday", within a week → weekday, older → date.
    static func chatListStamp(_ s: String?) -> String {
        guard let date = parse(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeOnly.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return weekdayOnly.string(from: date) }
        return dateOnly.string(from: date)
    }
}

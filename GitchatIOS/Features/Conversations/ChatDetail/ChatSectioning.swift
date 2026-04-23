import Foundation

/// Helpers for inserting day-boundary headers between messages. The
/// diffable data source identifiers use a `date-YYYY-MM-DD` prefix so
/// the cell provider can distinguish them from message IDs (which are
/// server-generated strings without a leading `date-`).
enum ChatSectioning {
    private static let iso = ISO8601DateFormatter()
    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Build a mixed list of `(id, Kind)` entries by walking the
    /// messages in order and emitting a header whenever adjacent
    /// messages cross a calendar day boundary (user's local calendar).
    static func snapshotIds(for messages: [Message]) -> [String] {
        guard !messages.isEmpty else { return [] }
        var out: [String] = []
        var lastKey = ""
        for m in messages {
            let date = m.created_at.flatMap { iso.date(from: $0) } ?? Date()
            let key = dayKeyFmt.string(from: date)
            if key != lastKey {
                out.append("date-\(key)")
                lastKey = key
            }
            out.append(m.id)
        }
        return out
    }

    static func isDateHeader(_ id: String) -> Bool {
        id.hasPrefix("date-")
    }

    /// Human label for a header id produced by `snapshotIds`. Returns
    /// "Today" / "Yesterday" / "12 Apr 2026".
    static func label(for headerId: String) -> String {
        guard headerId.hasPrefix("date-") else { return "" }
        let keyPart = String(headerId.dropFirst("date-".count))
        guard let date = dayKeyFmt.date(from: keyPart) else { return keyPart }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: Date())
            ? "d MMM"
            : "d MMM yyyy"
        return f.string(from: date)
    }
}

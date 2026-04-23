import Foundation

/// Groups messages into calendar-day sections for the UITableView
/// diffable data source. Section identifiers use the `date-YYYY-MM-DD`
/// shape so they never collide with server-generated message ids.
enum ChatV2Sectioning {

    /// A single day's worth of messages, ready for
    /// `snap.appendSections([sectionID])` +
    /// `snap.appendItems(messageIDs, toSection: sectionID)`.
    struct Group {
        let sectionID: String
        let messageIDs: [String]
    }

    private static let iso = ISO8601DateFormatter()
    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Walk `messages` in order and group consecutive runs that fall
    /// on the same local calendar day into a single `Group`.
    static func groupByDay(_ messages: [Message]) -> [Group] {
        guard !messages.isEmpty else { return [] }
        var groups: [Group] = []
        var currentKey = ""
        var currentIDs: [String] = []
        for m in messages {
            let date = m.created_at.flatMap { iso.date(from: $0) } ?? Date()
            let key = dayKeyFmt.string(from: date)
            if key != currentKey {
                if !currentIDs.isEmpty {
                    groups.append(Group(sectionID: "date-\(currentKey)", messageIDs: currentIDs))
                }
                currentKey = key
                currentIDs = [m.id]
            } else {
                currentIDs.append(m.id)
            }
        }
        if !currentIDs.isEmpty {
            groups.append(Group(sectionID: "date-\(currentKey)", messageIDs: currentIDs))
        }
        return groups
    }

    /// Returns the user-visible header label for a section identifier.
    /// "Today" / "Yesterday" / "12 Apr" (or "12 Apr 2026" across years).
    static func label(for sectionID: String) -> String {
        guard sectionID.hasPrefix("date-") else { return "" }
        let keyPart = String(sectionID.dropFirst("date-".count))
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

import SwiftUI

struct DatePillOverlay: View {
    let date: Date?

    var body: some View {
        if let date = date {
            Text(date.chatDateLabel)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .modifier(GlassPill())
                .transition(.opacity)
        }
    }
}

extension Date {
    private static let dayMonthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "d MMM"; return f
    }()
    private static let dayMonthYearFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "d MMM yyyy"; return f
    }()

    var chatDateLabel: String {
        if Calendar.current.isDateInToday(self) { return "Today" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday" }
        let sameYear = Calendar.current.component(.year, from: self) == Calendar.current.component(.year, from: Date())
        return (sameYear ? Self.dayMonthFmt : Self.dayMonthYearFmt).string(from: self)
    }
}

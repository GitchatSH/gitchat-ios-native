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
    var chatDateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateFormat = cal.component(.year, from: self) == cal.component(.year, from: Date())
            ? "d MMM"
            : "d MMM yyyy"
        return fmt.string(from: self)
    }
}

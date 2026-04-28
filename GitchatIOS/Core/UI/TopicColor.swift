import SwiftUI

enum TopicColorToken: String, CaseIterable, Hashable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    var color: Color {
        switch self {
        case .red:    return Color("TopicColorRed")
        case .orange: return Color("TopicColorOrange")
        case .yellow: return Color("TopicColorYellow")
        case .green:  return Color("TopicColorGreen")
        case .cyan:   return Color("TopicColorCyan")
        case .blue:   return Color("TopicColorBlue")
        case .purple: return Color("TopicColorPurple")
        case .pink:   return Color("TopicColorPink")
        }
    }

    /// Defaults to `.blue` for nil or any unrecognized token, matching the BE default.
    static func resolve(_ rawToken: String?) -> TopicColorToken {
        guard let raw = rawToken else { return .blue }
        return TopicColorToken(rawValue: raw.lowercased()) ?? .blue
    }
}

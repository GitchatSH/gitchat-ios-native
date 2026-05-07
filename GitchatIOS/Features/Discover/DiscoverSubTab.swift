import Foundation

enum DiscoverSubTab: String, CaseIterable, Identifiable {
    case people, teams, communities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people:      return "People"
        case .teams:       return "Teams"
        case .communities: return "Communities"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .people:      return "Search people..."
        case .teams:       return "Search teams..."
        case .communities: return "Search communities..."
        }
    }

    /// Communities pulls personalised starred repos and is meaningless
    /// for unauthenticated browsing. Guests see only People/Teams.
    static func cases(forGuest: Bool) -> [DiscoverSubTab] {
        forGuest ? [.people, .teams] : DiscoverSubTab.allCases
    }
}

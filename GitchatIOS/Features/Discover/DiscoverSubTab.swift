import Foundation

/// The three discover surfaces. Order matches the on-screen segmented
/// control. `searchPlaceholder` swaps the `.searchable` prompt so the
/// field hint tracks the active list's data source.
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
}

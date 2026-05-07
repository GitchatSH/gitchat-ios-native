import SwiftUI

struct GuestTabView: View {
    var body: some View {
        TabView {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari.fill") }

            UserSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

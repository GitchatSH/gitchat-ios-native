import SwiftUI

/// Root of the Discover tab (replaces the old Teams tab). Hosts three
/// horizontal sub-tabs: People / Teams / Communities. Per-sub-tab data
/// loading + filtering lives in `DiscoverViewModel`; the list rendering
/// lives in the three `DiscoverXList` views.
struct DiscoverView: View {
    @StateObject private var vm = DiscoverViewModel()
    @StateObject private var convos = ConversationsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $vm.subTab) {
                    ForEach(DiscoverSubTab.allCases) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                content
            }
            .navigationTitle("Discover")
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: vm.subTab.searchPlaceholder
            )
            .onChange(of: vm.subTab) { _ in vm.onSubTabChange() }
            .onChange(of: vm.query) { _ in vm.scheduleSearch() }
            .task {
                await vm.loadAll()
                await convos.load()
            }
            .refreshable {
                await vm.loadAll()
                await convos.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.subTab {
        case .people:      DiscoverPeopleList(vm: vm)
        case .teams:       DiscoverTeamsList(vm: vm, convosVM: convos)
        case .communities: DiscoverCommunitiesList(vm: vm, convosVM: convos)
        }
    }
}

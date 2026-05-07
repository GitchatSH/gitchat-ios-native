import SwiftUI

/// Root of the Discover tab (replaces the old Teams tab). Hosts three
/// horizontal sub-tabs: People / Teams / Communities. Per-sub-tab data
/// loading + filtering lives in `DiscoverViewModel`; the list rendering
/// lives in the three `DiscoverXList` views.
struct DiscoverView: View {
    @StateObject private var vm = DiscoverViewModel()
    @StateObject private var convos = ConversationsViewModel()
    @EnvironmentObject private var auth: AuthStore
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $vm.subTab) {
                    ForEach(DiscoverSubTab.cases(forGuest: !auth.isAuthenticated)) { t in
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
            .toolbar {
                if !auth.isAuthenticated {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Sign in") { showSignIn = true }
                            .font(.geist(15, weight: .semibold))
                    }
                }
            }
            .fullScreenCover(isPresented: $showSignIn) {
                NavigationStack {
                    SignInView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close") { showSignIn = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !auth.isAuthenticated {
            DiscoverGuestList(vm: vm)
        } else {
            switch vm.subTab {
            case .people:      DiscoverPeopleList(vm: vm)
            case .teams:       DiscoverTeamsList(vm: vm, convosVM: convos)
            case .communities: DiscoverCommunitiesList(vm: vm, convosVM: convos)
            }
        }
    }
}

private struct DiscoverGuestList: View {
    @ObservedObject var vm: DiscoverViewModel
    var body: some View {
        Group {
            if vm.trendingLoading && vm.trendingRepos.isEmpty {
                ProgressView().padding(.top, 40)
            } else if let err = vm.trendingError, vm.trendingRepos.isEmpty {
                VStack(spacing: 8) {
                    Text("Couldn't load trending").font(.headline)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await vm.loadAll() } }
                        .buttonStyle(.borderedProminent)
                }.padding(.top, 40)
            } else {
                List {
                    Section("Trending repos") {
                        ForEach(vm.trendingRepos) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.fullName).font(.headline)
                                if let d = r.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    Section("Trending people") {
                        ForEach(vm.trendingPeople) { u in
                            HStack {
                                AvatarView(url: u.avatar_url, size: 32, login: u.login)
                                VStack(alignment: .leading) {
                                    Text("@\(u.login)").font(.subheadline)
                                    if let n = u.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

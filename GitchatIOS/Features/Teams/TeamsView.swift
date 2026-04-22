import SwiftUI

@MainActor
final class TeamsViewModel: ObservableObject {
    @Published var teams: [Conversation] = []
    @Published var isLoading = false
    @Published var isSyncing = false

    func load() async {
        if teams.isEmpty { isLoading = true }
        isSyncing = true
        let start = Date()
        defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.listConversations(limit: 100)
            self.teams = resp.conversations.filter { $0.type == "team" }
        } catch { }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 2 {
            try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
        }
        isSyncing = false
    }
}

struct TeamsView: View {
    @StateObject private var vm = TeamsViewModel()
    @State private var filter = ""
    @State private var selected: Conversation?

    private var filtered: [Conversation] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vm.teams }
        return vm.teams.filter { c in
            c.displayTitle.lowercased().contains(q)
                || (c.repo_full_name ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.teams.isEmpty {
                    SkeletonList(count: 8, avatarSize: 44)
                } else if vm.teams.isEmpty {
                    ContentUnavailableCompat(
                        title: "No teams yet",
                        systemImage: "person.3",
                        description: "Team rooms for repos you contribute to show up here."
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableCompat(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        description: "Try a different search."
                    )
                } else {
                    List(filtered) { team in
                        Button { selected = team } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    url: team.group_avatar_url ?? team.repo_full_name.flatMap { "https://github.com/\($0.split(separator: "/").first ?? "").png" },
                                    size: 44
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.displayTitle).font(.headline)
                                    if let repo = team.repo_full_name {
                                        Text(repo).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("\(team.participantsOrEmpty.count) members")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if team.unreadCount > 0 {
                                    Text("\(team.unreadCount)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Color("AccentColor"), in: .capsule)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    #if !targetEnvironment(macCatalyst)
                    .scrollIndicators(.hidden)
                    #endif
                    .refreshable { await vm.load() }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search teams")
            .navigationTitle("Teams")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.isSyncing {
                        SyncingIndicator()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSyncing)
            .sheet(item: $selected) { team in
                NavigationStack {
                    ChatDetailView(conversation: team)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { selected = nil }
                            }
                        }
                }
            }
            .task { await vm.load() }
            .onAppear { Task { await vm.load() } }
        }
    }
}

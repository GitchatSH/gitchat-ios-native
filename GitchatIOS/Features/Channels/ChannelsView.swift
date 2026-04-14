import SwiftUI

@MainActor
final class ChannelsViewModel: ObservableObject {
    @Published var channels: [RepoChannel] = []
    @Published var isLoading = false

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.channels()
            self.channels = resp.channels
        } catch { }
    }
}

struct ChannelsView: View {
    @StateObject private var vm = ChannelsViewModel()
    @State private var filter = ""

    private var filtered: [RepoChannel] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vm.channels }
        return vm.channels.filter { c in
            (c.displayName ?? "").lowercased().contains(q)
                || c.repoOwner.lowercased().contains(q)
                || c.repoName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.channels.isEmpty {
                    SkeletonList(count: 8, avatarSize: 44)
                } else if vm.channels.isEmpty {
                    ContentUnavailableCompat(
                        title: "No channels",
                        systemImage: "number",
                        description: "Repo channels you subscribe to show up here."
                    )
                } else {
                    List(filtered) { c in
                        NavigationLink(value: c) {
                            HStack(spacing: 12) {
                                AvatarView(url: c.avatarUrl, size: 44)
                                VStack(alignment: .leading) {
                                    Text(c.displayName ?? "\(c.repoOwner)/\(c.repoName)").font(.headline)
                                    Text("\(c.subscriberCount) subscribers").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search channels")
            .navigationTitle("Channels")
            .navigationDestination(for: RepoChannel.self) { c in
                ChannelDetailView(channel: c)
            }
            .task { if vm.channels.isEmpty { await vm.load() } }
        }
    }
}

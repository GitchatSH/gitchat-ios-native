import SwiftUI

@MainActor
final class ChannelsViewModel: ObservableObject {
    @Published var channels: [RepoChannel] = []

    func load() async {
        do {
            let resp = try await APIClient.shared.channels()
            self.channels = resp.channels
        } catch { }
    }
}

struct ChannelsView: View {
    @StateObject private var vm = ChannelsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.channels.isEmpty {
                    ContentUnavailableCompat(
                        title: "No channels",
                        systemImage: "number",
                        description: "Repo channels you subscribe to show up here."
                    )
                } else {
                    List(vm.channels) { c in
                        HStack(spacing: 12) {
                            AvatarView(url: c.avatarUrl, size: 44)
                            VStack(alignment: .leading) {
                                Text(c.displayName ?? "\(c.repoOwner)/\(c.repoName)").font(.headline)
                                Text("\(c.subscriberCount) subscribers").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Channels")
            .task { await vm.load() }
        }
    }
}

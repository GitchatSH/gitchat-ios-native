import SwiftUI

@MainActor
final class ChannelFeedViewModel: ObservableObject {
    @Published var posts: [APIClient.ChannelPost] = []
    @Published var isLoading = false
    @Published var error: String?

    let channelId: String
    let source: String

    init(channelId: String, source: String) {
        self.channelId = channelId
        self.source = source
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.channelFeed(channelId: channelId, source: source)
            self.posts = resp.posts
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChannelDetailView: View {
    let channel: RepoChannel
    @State private var selectedTab = 0

    private let tabs: [(title: String, source: String, icon: String)] = [
        ("X", "x", "bubble.left"),
        ("YouTube", "youtube", "play.rectangle"),
        ("Gitchat", "gitchat", "bubble.left.and.bubble.right"),
        ("GitHub", "github", "chevron.left.forwardslash.chevron.right")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $selectedTab) {
                ForEach(tabs.indices, id: \.self) { i in
                    Text(tabs[i].title).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            ChannelFeedList(channelId: channel.id, source: tabs[selectedTab].source)
                .id("\(channel.id)-\(tabs[selectedTab].source)")
        }
        .navigationTitle(channel.displayName ?? "\(channel.repoOwner)/\(channel.repoName)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(url: channel.avatarUrl, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName ?? "\(channel.repoOwner)/\(channel.repoName)")
                    .font(.geist(17, weight: .bold))
                    .foregroundStyle(Color(.label))
                Text("\(channel.subscriberCount) subscribers")
                    .font(.geist(12, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                if let d = channel.description {
                    Text(d).font(.geist(13, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal).padding(.top, 12)
    }
}

struct ChannelFeedList: View {
    @StateObject private var vm: ChannelFeedViewModel

    init(channelId: String, source: String) {
        _vm = StateObject(wrappedValue: ChannelFeedViewModel(channelId: channelId, source: source))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.posts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.posts.isEmpty {
                ContentUnavailableCompat(
                    title: "Nothing yet",
                    systemImage: "tray",
                    description: "No posts on this feed."
                )
            } else {
                List(vm.posts) { post in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            AvatarView(url: post.authorAvatar, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(post.authorName ?? post.authorHandle ?? "unknown")
                                    .font(.geist(14, weight: .semibold))
                                if let handle = post.authorHandle {
                                    Text("@\(handle)").font(.geist(11, weight: .regular)).foregroundStyle(Color(.secondaryLabel))
                                }
                            }
                        }
                        if let body = post.body {
                            Text(body).font(.geist(14, weight: .regular))
                        }
                        if let urls = post.mediaUrls, let first = urls.first, let u = URL(string: first) {
                            AsyncImage(url: u) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFit()
                                default: Color(.secondarySystemBackground).frame(height: 120)
                                }
                            }
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
                .refreshable { await vm.load() }
            }
        }
        .task { await vm.load() }
    }
}

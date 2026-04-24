import SwiftUI

struct DiscoverPeopleList: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject private var presence = PresenceStore.shared
    #if targetEnvironment(macCatalyst)
    @ObservedObject private var router = AppRouter.shared
    #endif

    var body: some View {
        let rows = vm.peopleRows()
        Group {
            if vm.peopleLoading && rows.isEmpty {
                SkeletonList(count: 10, avatarSize: 40)
            } else if let err = vm.peopleError, rows.isEmpty {
                errorState(err)
            } else if rows.isEmpty {
                emptyState
            } else {
                List(rows) { user in
                    rowLink(for: user) {
                        HStack(spacing: 12) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(url: user.avatar_url, size: macRowAvatarSize, login: user.login)
                                if presence.isOnline(user.login) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 10, height: 10)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name ?? user.login).font(.headline)
                                Text("@\(user.login)").font(macRowSubtitleFont).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        #if targetEnvironment(macCatalyst)
                        .padding(.horizontal, macRowHorizontalPadding)
                        .padding(.vertical, macRowVerticalPadding)
                        .contentShape(Rectangle())
                        #endif
                    }
                    .listRowSeparator(.hidden)
                    #if targetEnvironment(macCatalyst)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    #endif
                    .hideMacScrollIndicators()
                }
                .listStyle(.plain)
                .macRowListContainer()
                .scrollIndicators(.hidden, axes: .vertical)
            }
        }
        .onAppear { presence.ensure(vm.peopleRows().map(\.login)) }
    }

    /// Catalyst routes profile taps through `AppRouter.selectedProfile`
    /// so the detail panel can render them. A plain `NavigationLink`
    /// would push into `NavigationSplitView`'s own detail stack, which
    /// outlives tab switches and leaves a stale profile stranded.
    @ViewBuilder
    private func rowLink<Label: View>(for user: FriendUser, @ViewBuilder label: () -> Label) -> some View {
        #if targetEnvironment(macCatalyst)
        Button {
            router.selectedProfile = user.login
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #else
        NavigationLink { ProfileView(login: user.login) } label: { label() }
        #endif
    }

    private var emptyState: some View {
        let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentUnavailableCompat(
            title: q.isEmpty ? "No mutual follows yet" : "No people match \"\(q)\"",
            systemImage: q.isEmpty ? "person.2" : "magnifyingglass",
            description: q.isEmpty
                ? "Follow people on GitHub to see them here."
                : "Try a different handle or name."
        )
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Couldn't load people").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadMutuals() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

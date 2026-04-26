import SwiftUI

/// Principal toolbar view: chat title + subtitle. Subtitle priority:
///   1. "syncing up..." while a sync is in flight
///   2. for 1:1 chats: "online" or "last seen ..." for the other user
///   3. for group chats: "N online" (at least 1)
struct ChatDetailTitleBar: View {
    let conversation: Conversation
    @ObservedObject var vm: ChatViewModel
    var onTap: (() -> Void)? = nil
    @ObservedObject private var presence = PresenceStore.shared

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(conversation.displayTitle)
                    .font(.headline)
                if vm.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if vm.isSyncing {
                SyncingDotsLabel()
                    .transition(.opacity)
            } else if let sub = subtitleInfo {
                sub.view
                    .font(.caption2)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isSyncing)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onAppear {
            if conversation.isGroup {
                presence.ensure(conversation.participantsOrEmpty.map(\.login))
            } else if let login = conversation.other_user?.login {
                presence.ensure([login])
            }
        }
    }

    private struct SubtitleInfo {
        let view: AnyView
    }

    private var subtitleInfo: SubtitleInfo? {
        if conversation.isGroup {
            let participants = conversation.participantsOrEmpty.map(\.login)
            guard !participants.isEmpty else { return nil }
            let onlineCount = participants.filter { presence.isOnline($0) }.count
            if onlineCount > 0 {
                return SubtitleInfo(view: AnyView(
                    HStack(spacing: 0) {
                        Text("\(participants.count) members, ")
                            .foregroundStyle(.secondary)
                        Text("\(onlineCount) online")
                            .foregroundStyle(.green)
                    }
                ))
            } else {
                return SubtitleInfo(view: AnyView(
                    Text("\(participants.count) members")
                        .foregroundStyle(.secondary)
                ))
            }
        }
        guard let login = conversation.other_user?.login else { return nil }
        if presence.isOnline(login) {
            return SubtitleInfo(view: AnyView(
                Text("online").foregroundStyle(.green)
            ))
        }
        if let date = presence.lastSeen[login] {
            return SubtitleInfo(view: AnyView(
                Text(Self.relative(date)).foregroundStyle(.secondary)
            ))
        }
        return nil
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "last seen just now" }
        let mins = seconds / 60
        if mins < 60 { return "last seen \(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "last seen \(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "last seen yesterday" }
        return "last seen \(days)d ago"
    }
}

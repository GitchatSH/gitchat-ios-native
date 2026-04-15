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
            Text(conversation.displayTitle)
                .font(.headline)
            if vm.isSyncing {
                SyncingDotsLabel()
                    .transition(.opacity)
            } else if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private var subtitle: String? {
        if conversation.isGroup {
            let participants = conversation.participantsOrEmpty.map(\.login)
            guard !participants.isEmpty else { return nil }
            let onlineCount = participants.filter { presence.isOnline($0) }.count
            return "\(onlineCount)/\(participants.count) online"
        }
        guard let login = conversation.other_user?.login else { return nil }
        if presence.isOnline(login) { return "online" }
        if let date = presence.lastSeen[login] {
            return "last seen \(Self.relative(date))"
        }
        return nil
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let mins = seconds / 60
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}

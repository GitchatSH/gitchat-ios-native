import SwiftUI

/// Horizontal chips rendered above the composer when the user typed
/// `@…` in a group chat. Tap inserts the mention at the current
/// cursor position (handled by the parent).
struct ChatMentionSuggestionRow: View {
    let suggestions: [ConversationParticipant]
    let onPick: (ConversationParticipant) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { p in
                    Button { onPick(p) } label: {
                        HStack(spacing: 6) {
                            AvatarView(url: p.avatar_url, size: 22)
                            Text("@\(p.login)")
                                .font(.geist(13, weight: .semibold))
                                .foregroundStyle(Color(.label))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

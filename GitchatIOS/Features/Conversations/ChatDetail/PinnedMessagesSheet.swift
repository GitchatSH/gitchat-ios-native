import SwiftUI

struct PinnedMessagesSheet: View {
    let conversation: Conversation
    var onSelect: ((String) -> Void)? = nil
    @State private var messages: [Message] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                SkeletonList(count: 5, avatarSize: 28)
            } else if messages.isEmpty {
                ContentUnavailableCompat(
                    title: "No pinned messages",
                    systemImage: "pin",
                    description: "Long-press a message and tap Pin."
                )
            } else {
                List(messages) { m in
                    Button {
                        onSelect?(m.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("@\(m.sender)").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(m.content).font(.subheadline).foregroundStyle(Color(.label))
                            Text(RelativeTime.format(m.created_at))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                #if !targetEnvironment(macCatalyst)
            .scrollContentBackground(.hidden)
            #endif
                #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
            }
        }
        .navigationTitle("Pinned")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        .task {
            do {
                messages = try await APIClient.shared.pinnedMessages(conversationId: conversation.id)
            } catch {}
            isLoading = false
        }
    }
}

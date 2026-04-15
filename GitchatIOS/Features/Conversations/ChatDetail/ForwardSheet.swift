import SwiftUI

struct ForwardSheet: View {
    let message: Message
    @State private var conversations: [Conversation] = []
    @State private var selected: Set<String> = []
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(conversations) { c in
            Button {
                Haptics.selection()
                if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
            } label: {
                HStack {
                    AvatarView(url: c.displayAvatarURL, size: 36)
                    Text(c.displayTitle).foregroundStyle(Color(.label))
                    Spacer()
                    Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(c.id) ? Color.accentColor : Color(.tertiaryLabel))
                }
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .navigationTitle("Forward to…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    Task {
                        isSending = true
                        do {
                            try await APIClient.shared.forwardMessage(messageId: message.id, toConversationIds: Array(selected))
                            ToastCenter.shared.show(.success, "Forwarded", "to \(selected.count) chat\(selected.count == 1 ? "" : "s")")
                            dismiss()
                        } catch {
                            ToastCenter.shared.show(.error, "Forward failed", error.localizedDescription)
                        }
                        isSending = false
                    }
                }
                .disabled(selected.isEmpty || isSending)
            }
        }
        .task {
            do {
                let resp = try await APIClient.shared.listConversations()
                conversations = resp.conversations
            } catch {}
        }
    }
}

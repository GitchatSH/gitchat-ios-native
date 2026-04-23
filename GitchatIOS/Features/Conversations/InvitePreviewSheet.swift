import SwiftUI

/// Shown after the user taps a `gitchat://invite/<code>` link. Fetches
/// `GET /messages/conversations/join/<code>` for a preview of the group,
/// then joins via `POST` on confirm.
struct InvitePreviewSheet: View {
    let code: String
    var onJoined: ((Conversation) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var preview: APIClient.InvitePreview?
    @State private var loading = true
    @State private var joining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    errorState(error)
                } else if let preview {
                    body(for: preview)
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func body(for preview: APIClient.InvitePreview) -> some View {
        VStack(spacing: 20) {
            AvatarView(url: preview.group_avatar_url, size: 88)

            VStack(spacing: 4) {
                Text(preview.group_name ?? "Gitchat group")
                    .font(.title3.weight(.semibold))
                if let count = preview.member_count {
                    Text("\(count) member\(count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isAlreadyMember(preview) {
                Button {
                    let id = preview.conversation_id ?? localConversationId(for: preview)
                    dismiss()
                    if let id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            AppRouter.shared.openConversation(id: id)
                        }
                    }
                } label: {
                    Label("Open chat", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await join() }
                } label: {
                    if joining {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Join group", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(joining)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func errorState(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This invite link is invalid or expired.")
                .multilineTextAlignment(.center)
            Text(error)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// True when BE explicitly flagged `already_member`, or the previewed
    /// conversation shows up in our locally-cached conversation list
    /// (BE's flag naming isn't in swagger — this fallback covers cases
    /// where it returns the code/name but no `already_member`).
    private func isAlreadyMember(_ preview: APIClient.InvitePreview) -> Bool {
        if preview.already_member == true { return true }
        if localConversationId(for: preview) != nil { return true }
        return false
    }

    /// Look up the preview against the cached conversations. Matches by
    /// `conversation_id` first, then by group name as a soft fallback.
    private func localConversationId(for preview: APIClient.InvitePreview) -> String? {
        let cached = ConversationsCache.shared.get() ?? []
        if let cid = preview.conversation_id,
           cached.contains(where: { $0.id == cid }) {
            return cid
        }
        if let name = preview.group_name?.lowercased(), !name.isEmpty,
           let match = cached.first(where: { $0.isGroup && $0.group_name?.lowercased() == name }) {
            return match.id
        }
        return nil
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            preview = try await APIClient.shared.previewInvite(code: code)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            let conversation = try await APIClient.shared.joinByInvite(code: code)
            ToastCenter.shared.show(.success, "Joined \(preview?.group_name ?? "group")")
            onJoined?(conversation)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                AppRouter.shared.openConversation(id: conversation.id)
            }
        } catch {
            ToastCenter.shared.show(.error, "Couldn't join", error.localizedDescription)
        }
    }
}

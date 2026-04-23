import SwiftUI

/// Extracted view modifier holding the group-management sheets/alerts
/// so `ChatDetailView.chatBody` stays under Swift's type-checker budget.
struct GroupManagementSheets: ViewModifier {
    let conversation: Conversation
    @Binding var showInviteLink: Bool
    @Binding var showGroupSettings: Bool
    @Binding var showDeleteConfirm: Bool
    let onSettingsSaved: () -> Void
    let onDeleteConfirmed: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showInviteLink) {
                GroupInviteLinkSheet(
                    conversationId: conversation.id,
                    groupName: conversation.group_name
                )
            }
            .sheet(isPresented: $showGroupSettings) {
                GroupSettingsSheet(conversation: conversation, onSaved: onSettingsSaved)
            }
            .alert("Delete group?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive, action: onDeleteConfirmed)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the group for everyone. Only the creator can delete.")
            }
    }
}

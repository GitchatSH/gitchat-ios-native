import Foundation

extension APIClient {

    /// Rename / change avatar on a group conversation. BE accepts partial
    /// updates — pass only the field(s) that changed. The avatar URL must
    /// come from an earlier upload via `uploadAttachment`.
    func updateGroup(id: String, name: String? = nil, avatarUrl: String? = nil) async throws {
        struct Body: Encodable {
            let group_name: String?
            let group_avatar_url: String?
        }
        let _: EmptyResponse = try await request(
            "messages/conversations/\(id)/group",
            method: "PATCH",
            body: Body(group_name: name, group_avatar_url: avatarUrl)
        )
    }

    /// Delete/disband a group (creator only). Backend returns 403 if the
    /// caller isn't the creator.
    func disbandGroup(id: String) async throws {
        let _: EmptyResponse = try await request(
            "messages/conversations/\(id)/group",
            method: "DELETE"
        )
    }

    /// Remove a member from a group (admin only). The dedicated `/kick`
    /// endpoint is the canonical one; `DELETE /members/:login` exists too
    /// but `/kick` is what the extension uses.
    func kickMember(conversationId: String, login: String) async throws {
        struct Body: Encodable { let login: String }
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/kick",
            method: "POST",
            body: Body(login: login)
        )
    }

    /// Promote a 1-on-1 DM into a group conversation, preserving history.
    /// Use this when a user wants to add a third participant: call this
    /// first, then `addMember` for the new recipient.
    func convertToGroup(id: String) async throws -> Conversation {
        struct Empty: Encodable {}
        return try await request(
            "messages/conversations/\(id)/convert-to-group",
            method: "POST",
            body: Empty()
        )
    }
}

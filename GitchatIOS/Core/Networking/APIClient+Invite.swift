import Foundation

extension APIClient {

    struct InviteLink: Decodable, Hashable {
        let code: String
        let url: String?
        let expires_at: String?
        /// Some BE shapes nest the payload under `invite`.
        private enum CodingKeys: String, CodingKey {
            case code, url, expires_at, invite
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let code = try? c.decode(String.self, forKey: .code) {
                self.code = code
                self.url = try? c.decode(String.self, forKey: .url)
                self.expires_at = try? c.decode(String.self, forKey: .expires_at)
                return
            }
            // Fall through to a nested shape: { invite: { code, url, expires_at } }
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .invite)
            self.code = try inner.decode(String.self, forKey: .code)
            self.url = try? inner.decode(String.self, forKey: .url)
            self.expires_at = try? inner.decode(String.self, forKey: .expires_at)
        }
    }

    struct InvitePreview: Decodable, Hashable {
        let code: String?
        let group_name: String?
        let group_avatar_url: String?
        let member_count: Int?
        let expires_at: String?
        let already_member: Bool?
        let conversation_id: String?
    }

    /// Create or fetch the active invite link for a group. BE may return
    /// the existing active link rather than rotating on every call — to
    /// rotate, call `revokeInviteLink` first, then this again.
    func createInviteLink(conversationId: String) async throws -> InviteLink {
        struct Empty: Encodable {}
        return try await request(
            "messages/conversations/\(conversationId)/invite",
            method: "POST",
            body: Empty()
        )
    }

    /// Revoke the active invite link. Next `createInviteLink` will issue a
    /// fresh code.
    func revokeInviteLink(conversationId: String) async throws {
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/invite",
            method: "DELETE"
        )
    }

    /// Unauthenticated-friendly preview — used before the user commits to
    /// joining. Backend may still require auth; if so the user has already
    /// signed in anyway by the time they land on this screen.
    func previewInvite(code: String) async throws -> InvitePreview {
        try await request("messages/conversations/join/\(code)")
    }

    /// Join a group via invite code. Returns the conversation so the UI
    /// can navigate straight in on success.
    func joinByInvite(code: String) async throws -> Conversation {
        struct Empty: Encodable {}
        return try await request(
            "messages/conversations/join/\(code)",
            method: "POST",
            body: Empty()
        )
    }
}

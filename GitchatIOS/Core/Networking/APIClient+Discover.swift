import Foundation

extension APIClient {

    struct StarredRepo: Decodable, Identifiable, Hashable {
        let owner: String
        let name: String
        let description: String?
        let language: String?
        let stars: Int?
        let forks: Int?
        let topics: [String]?
        let avatar_url: String?
        let has_discussions: Bool?
        var id: String { "\(owner)/\(name)" }
        var fullName: String { "\(owner)/\(name)" }
    }

    struct ContributedRepo: Decodable, Identifiable, Hashable {
        let owner: String
        let name: String
        let description: String?
        let language: String?
        let stars: Int?
        let avatarUrl: String?
        let htmlUrl: String?
        let commitCount: Int?
        let firstContribAt: String?
        let lastContribAt: String?
        var id: String { "\(owner)/\(name)" }
        var fullName: String { "\(owner)/\(name)" }
    }

    // MARK: - Discover sources

    /// Mutual followers — both follow each other on GitHub AND have Gitchat.
    /// BE: `GET /github/data/friends` → `{ mutual, notOnGitchat, ... }`.
    func friendsMutual() async throws -> [FriendUser] {
        struct Resp: Decodable {
            let mutual: [FriendUser]
            let notOnGitchat: [FriendUser]?
        }
        let r: Resp = try await request("github/data/friends")
        return r.mutual
    }

    /// `GET /github/data/starred` → `{ repos: StarredRepo[] }`.
    func fetchStarredRepos() async throws -> [StarredRepo] {
        struct Resp: Decodable { let repos: [StarredRepo] }
        let r: Resp = try await request("github/data/starred")
        return r.repos
    }

    /// `GET /github/data/contributed` → `{ repos: ContributedRepo[] }`.
    func fetchContributedRepos() async throws -> [ContributedRepo] {
        struct Resp: Decodable { let repos: [ContributedRepo] }
        let r: Resp = try await request("github/data/contributed")
        return r.repos
    }

    // MARK: - Join flows (shared with #33)

    /// Join a repo's Team channel via `POST /messages/conversations` with
    /// `{ type: "team", repo_full_name }`. Returns the resulting (or
    /// pre-existing) conversation.
    func joinTeam(repoFullName: String) async throws -> Conversation {
        struct Body: Encodable {
            let type: String
            let repo_full_name: String
        }
        return try await request(
            "messages/conversations",
            method: "POST",
            body: Body(type: "team", repo_full_name: repoFullName)
        )
    }

    func joinCommunity(repoFullName: String) async throws -> Conversation {
        struct Body: Encodable {
            let type: String
            let repo_full_name: String
        }
        return try await request(
            "messages/conversations",
            method: "POST",
            body: Body(type: "community", repo_full_name: repoFullName)
        )
    }

    // MARK: - Waves (#35)

    struct WaveSent: Decodable {
        /// Wave id. BE field is `id`.
        let id: String
        let fromLogin: String?
        let toLogin: String?
        let status: String?
        let createdAt: String?
    }

    struct WaveAccepted: Decodable {
        let waveId: String
        /// DM conversation id created (or existing) for the pair.
        let conversationId: String
    }

    /// Send a one-tap wave to `login`. BE creates only a notification —
    /// no message, no conversation — until the recipient responds.
    /// 409 on duplicate; 400 when waving yourself.
    func sendWave(to login: String) async throws -> WaveSent {
        struct Body: Encodable { let toLogin: String }
        return try await request("waves", method: "POST", body: Body(toLogin: login))
    }

    /// Accept a wave — BE atomically creates the DM and emits
    /// `wave:responded` on the sender's socket. Returns the new
    /// (or pre-existing) conversation id.
    func respondToWave(waveId: String) async throws -> WaveAccepted {
        struct Empty: Encodable {}
        return try await request("waves/\(waveId)/respond", method: "POST", body: Empty())
    }
}

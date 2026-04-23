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
}

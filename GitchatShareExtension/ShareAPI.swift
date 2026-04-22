import Foundation
import UIKit

struct ShareConversation: Identifiable, Decodable {
    let id: String
    let type: String?
    let group_name: String?
    let other_user: OtherUser?
    let participants: [Participant]?
    let repo_full_name: String?
    let group_avatar_url: String?

    struct OtherUser: Decodable {
        let login: String
        let name: String?
        let avatar_url: String?
    }

    struct Participant: Decodable {
        let login: String
        let name: String?
        let avatar_url: String?
    }

    var title: String {
        if let name = group_name, !name.isEmpty { return name }
        if let other = other_user { return other.name ?? other.login }
        if let repo = repo_full_name { return repo }
        return "Conversation"
    }

    var subtitle: String? {
        if let other = other_user { return "@\(other.login)" }
        if let repo = repo_full_name, group_name != nil { return repo }
        if let n = participants?.count { return "\(n) members" }
        return nil
    }

    var avatarURL: String? {
        if let url = group_avatar_url { return url }
        if let other = other_user { return other.avatar_url }
        if let repo = repo_full_name, let org = repo.split(separator: "/").first {
            return "https://github.com/\(org).png"
        }
        return nil
    }
}

struct ShareAttachment {
    var data: Data
    var filename: String
    var mimeType: String
}

enum ShareAPIError: LocalizedError {
    case notAuthenticated
    case http(Int, String?)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in — open Gitchat and sign in first."
        case .http(let code, let msg): return "HTTP \(code)\(msg.map { ": \($0)" } ?? "")"
        case .transport(let e): return e.localizedDescription
        }
    }
}

struct ShareAPI {
    static let shared = ShareAPI()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.httpAdditionalHeaders = [
            "User-Agent": ShareConfig.userAgent,
            "Accept": "application/json"
        ]
        self.session = URLSession(configuration: cfg)
    }

    private func authHeader() throws -> String {
        guard let token = ShareTokenStore.token() else {
            throw ShareAPIError.notAuthenticated
        }
        return "Bearer \(token)"
    }

    func listConversations(limit: Int = 50) async throws -> [ShareConversation] {
        var comps = URLComponents(url: ShareConfig.apiBaseURL.appendingPathComponent("messages/conversations"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        var req = URLRequest(url: comps.url!)
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")

        let (data, resp) = try await session.data(for: req)
        try check(resp, data)

        struct Env: Decodable {
            let conversations: [ShareConversation]?
            let data: Inner?
            struct Inner: Decodable { let conversations: [ShareConversation]? }
        }
        let env = try JSONDecoder().decode(Env.self, from: data)
        return env.conversations ?? env.data?.conversations ?? []
    }

    func uploadAttachment(_ att: ShareAttachment, conversationId: String) async throws -> String {
        let boundary = "gitchat-\(UUID().uuidString)"
        var req = URLRequest(url: ShareConfig.apiBaseURL.appendingPathComponent("messages/upload"))
        req.httpMethod = "POST"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"conversation_id\"\r\n\r\n\(conversationId)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(att.filename)\"\r\n")
        append("Content-Type: \(att.mimeType)\r\n\r\n")
        body.append(att.data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        try check(resp, data)

        struct Env: Decodable { let data: Inner?; let url: String? }
        struct Inner: Decodable { let url: String }
        let env = try JSONDecoder().decode(Env.self, from: data)
        guard let url = env.data?.url ?? env.url else {
            throw ShareAPIError.http(200, "no url in response")
        }
        return url
    }

    func sendMessage(conversationId: String, body: String, attachmentURLs: [String] = []) async throws {
        var req = URLRequest(url: ShareConfig.apiBaseURL.appendingPathComponent("messages/conversations/\(conversationId)"))
        req.httpMethod = "POST"
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["body": body]
        if !attachmentURLs.isEmpty {
            payload["attachments"] = attachmentURLs.map { ["url": $0] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw ShareAPIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ShareAPIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }
}

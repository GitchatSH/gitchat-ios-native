import Foundation

// MARK: - APIClientProtocol

/// Abstraction over the network layer used by OutboxStore and tested via MockAPIClient.
protocol APIClientProtocol {
    func sendMessage(
        conversationID: String,
        body: String,
        attachments: [[String: Any]],
        replyToID: String?,
        clientMessageID: String?
    ) async throws -> Message

    func uploadAttachment(
        conversationID: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRef
}

// MARK: - APIClient conformance

extension APIClient: APIClientProtocol {

    func sendMessage(
        conversationID: String,
        body: String,
        attachments: [[String: Any]],
        replyToID: String?,
        clientMessageID: String?
    ) async throws -> Message {
        // Build the JSON body manually via JSONSerialization so the full
        // attachment shape (type, url, storage_path, mime_type, size_bytes,
        // width, height, blurhash) is forwarded without losing numeric types.
        var jsonObj: [String: Any] = ["body": body]
        if let replyToID { jsonObj["reply_to_id"] = replyToID }
        if let clientMessageID { jsonObj["client_message_id"] = clientMessageID }
        let validAttachments = attachments.filter { ($0["url"] as? String) != nil }
        if !validAttachments.isEmpty { jsonObj["attachments"] = validAttachments }

        let jsonData = try JSONSerialization.data(withJSONObject: jsonObj)

        var req = URLRequest(url: Config.apiBaseURL.appendingPathComponent("messages/conversations/\(conversationID)"))
        req.httpMethod = "POST"
        guard let token = await AuthStore.shared.accessToken else { throw APIError.notAuthenticated }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        if let wrapped = try? decoder.decode(APIEnvelope<Message>.self, from: data), let inner = wrapped.data {
            return inner
        }
        return try decoder.decode(Message.self, from: data)
    }

    /// Wraps `uploadAttachment(data:filename:mimeType:conversationId:)` which now
    /// returns a full `UploadedRef` decoded from the upload response.
    func uploadAttachment(
        conversationID: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRef {
        let ext = mimeType.split(separator: "/").last.map(String.init) ?? "bin"
        let filename = "upload.\(ext)"
        return try await uploadAttachment(
            data: data,
            filename: filename,
            mimeType: mimeType,
            conversationId: conversationID
        )
    }
}

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
        // Map the protocol's [[String: Any]] attachment dicts into the
        // [[String: String]] that the existing sendMessage(conversationId:…)
        // already encodes correctly.
        let stringDicts: [[String: String]] = attachments.compactMap { dict in
            guard let url = dict["url"] as? String else { return nil }
            var out: [String: String] = ["url": url]
            if let sp = dict["storage_path"] as? String { out["storage_path"] = sp }
            return out
        }
        let attachmentURLs: [String]? = stringDicts.isEmpty ? nil : stringDicts.map { $0["url"] ?? "" }
        return try await sendMessage(
            conversationId: conversationID,
            body: body,
            replyTo: replyToID,
            attachmentURL: nil,
            attachmentURLs: attachmentURLs,
            clientMessageID: clientMessageID
        )
    }

    /// Wraps the existing `uploadAttachment(data:filename:mimeType:conversationId:)`
    /// which returns a plain URL string, and adapts it to the `UploadedRef` shape
    /// that the FSM needs.
    ///
    /// Known V1 limitation: the upload endpoint returns only a URL; `storagePath`
    /// is left empty and `sizeBytes` is taken from the raw data length because the
    /// backend does not currently echo those fields back to iOS.
    func uploadAttachment(
        conversationID: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRef {
        let ext = mimeType.split(separator: "/").last.map(String.init) ?? "bin"
        let filename = "upload.\(ext)"
        let url = try await uploadAttachment(
            data: data,
            filename: filename,
            mimeType: mimeType,
            conversationId: conversationID
        )
        return UploadedRef(url: url, storagePath: "", sizeBytes: data.count)
    }
}

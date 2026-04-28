import Foundation
@testable import Gitchat

/// Test double for APIClientProtocol. Configure `sendStub` and `uploadStub`
/// before each test; the corresponding method calls the stub and returns its
/// result (or fatalErrors if the stub was not set).
final class MockAPIClient: APIClientProtocol {

    var sendStub: ((
        _ conversationID: String,
        _ body: String,
        _ attachments: [[String: Any]],
        _ replyToID: String?,
        _ clientMessageID: String?
    ) async throws -> Message)?

    var uploadStub: ((
        _ conversationID: String,
        _ data: Data,
        _ mimeType: String
    ) async throws -> UploadedRef)?

    func sendMessage(
        conversationID: String,
        body: String,
        attachments: [[String: Any]],
        replyToID: String?,
        clientMessageID: String?
    ) async throws -> Message {
        guard let stub = sendStub else {
            fatalError("MockAPIClient.sendStub was not configured for this test")
        }
        return try await stub(conversationID, body, attachments, replyToID, clientMessageID)
    }

    func uploadAttachment(
        conversationID: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRef {
        guard let stub = uploadStub else {
            fatalError("MockAPIClient.uploadStub was not configured for this test")
        }
        return try await stub(conversationID, data, mimeType)
    }
}

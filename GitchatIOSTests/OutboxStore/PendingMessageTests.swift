import XCTest
@testable import Gitchat

final class PendingMessageTests: XCTestCase {
    func test_init_textOnly_hasEmptyAttachments() {
        let p = PendingMessage(
            clientMessageID: "cmid-1",
            conversationID: "conv-1",
            content: "hi",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        )
        XCTAssertEqual(p.clientMessageID, "cmid-1")
        XCTAssertEqual(p.conversationID, "conv-1")
        XCTAssertEqual(p.content, "hi")
        XCTAssertNil(p.replyToID)
        XCTAssertTrue(p.attachments.isEmpty)
        XCTAssertEqual(p.attempts, 0)
        if case .enqueued = p.state {
            // ok
        } else {
            XCTFail("expected .enqueued state")
        }
    }

    func test_state_uploadingCarriesProgress() {
        let p = PendingMessage(
            clientMessageID: "cmid-2", conversationID: "c", content: "",
            replyToID: nil, attachments: [],
            attempts: 0, createdAt: Date(),
            state: .uploading(progress: 0.42)
        )
        if case .uploading(let progress) = p.state {
            XCTAssertEqual(progress, 0.42, accuracy: 0.001)
        } else {
            XCTFail("expected .uploading state")
        }
    }

    func test_state_failedCarriesReasonAndRetriable() {
        let p = PendingMessage(
            clientMessageID: "cmid-3", conversationID: "c", content: "",
            replyToID: nil, attachments: [],
            attempts: 1, createdAt: Date(),
            state: .failed(reason: "timeout", retriable: true)
        )
        if case .failed(let reason, let retriable) = p.state {
            XCTAssertEqual(reason, "timeout")
            XCTAssertTrue(retriable)
        } else {
            XCTFail("expected .failed state")
        }
    }

    func test_optimisticMessageId_derivesFromClientMessageID() {
        XCTAssertEqual(PendingMessage.optimisticID(for: "abc-uuid"), "local-abc-uuid")
    }
}

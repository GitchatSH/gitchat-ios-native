import XCTest
@testable import Gitchat

/// Unit tests for the OneSignal NSE compact-preview path. The pure
/// extraction + synthesis pipeline lives in `CompactPreviewPayload`
/// (compiled into both the main app target and the NSE target via
/// `project.yml`) so we can exercise it here without any OneSignal SDK
/// or `UNNotificationContent` mocks.
final class CompactPreviewPayloadTests: XCTestCase {
    // MARK: - No-op cases

    func test_textOnlyDM_returnsNil_unchanged() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": ["sender_login": "alice"]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hello")
        // formatter returns "hello" == currentBody → nil
        XCTAssertNil(result)
    }

    func test_emptyPayload_returnsNil() {
        let result = CompactPreviewPayload.formattedBody(userInfo: [:], currentBody: "hello")
        XCTAssertNil(result)
    }

    // MARK: - Structured forward path

    func test_dm_structuredForward_addsArrowPrefix() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "forwarded_from_original_author": "alice"
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hello")
        XCTAssertEqual(result, "↪ @alice: hello")
    }

    // MARK: - Legacy forward path (no structured field, body has prefix)

    func test_dm_legacyForwardBody_isParsedAndStripped() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": ["sender_login": "bob"]]
        ]
        let result = CompactPreviewPayload.formattedBody(
            userInfo: userInfo,
            currentBody: "> Forwarded from @alice\n\nhello"
        )
        XCTAssertEqual(result, "↪ @alice: hello")
    }

    // MARK: - Attachment path

    func test_dm_imageOnly_returnsPhotoLabel() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "attachment_type": "image",
                "attachment_thumb_url": "https://x/1-t.jpg"
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "")
        XCTAssertEqual(result, "📷 Photo")
    }

    func test_dm_fileWithFilename_returnsFileLabel() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "attachment_type": "file",
                "attachment_filename": "report.pdf"
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "")
        XCTAssertEqual(result, "📎 report.pdf")
    }

    // MARK: - Group prefix

    func test_group_addsSenderPrefix() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "is_group": true
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hi")
        XCTAssertEqual(result, "bob: hi")
    }

    func test_group_forward_addsBothPrefixes() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "is_group": true,
                "forwarded_from_original_author": "carol"
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hi")
        XCTAssertEqual(result, "bob: ↪ @carol: hi")
    }

    // MARK: - is_group triple-cast

    func test_isGroup_parsedFromNSNumber() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "is_group": NSNumber(booleanLiteral: true)
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hi")
        XCTAssertEqual(result, "bob: hi")
    }

    func test_isGroup_parsedFromString() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "sender_login": "bob",
                "is_group": "true"
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hi")
        XCTAssertEqual(result, "bob: hi")
    }

    // MARK: - actor_login fallback

    func test_actorLoginFallback_whenSenderLoginAbsent() {
        let userInfo: [AnyHashable: Any] = [
            "custom": ["a": [
                "actor_login": "bob",
                "is_group": true
            ]]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hi")
        XCTAssertEqual(result, "bob: hi")
    }

    // MARK: - userInfo["data"] fallback (no custom.a)

    func test_userInfoData_fallbackPath() {
        let userInfo: [AnyHashable: Any] = [
            "data": [
                "sender_login": "bob",
                "forwarded_from_original_author": "alice"
            ]
        ]
        let result = CompactPreviewPayload.formattedBody(userInfo: userInfo, currentBody: "hello")
        XCTAssertEqual(result, "↪ @alice: hello")
    }
}

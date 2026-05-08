import XCTest
@testable import Gitchat

final class MessagePreviewFormatterTests: XCTestCase {
    func test_textOnly_dm_returnsTextAsIs() {
        let m = makeMessage(content: "hello")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "hello")
        XCTAssertNil(out.thumbURL)
    }

    func test_imageOnly_dm_returnsPhotoLabel() {
        let m = makeMessage(
            content: "",
            attachments: [att(type: "image", url: "https://x/1.jpg", thumbnailUrl: "https://x/1-t.jpg")]
        )
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "📷 Photo")
        XCTAssertEqual(out.thumbURL, URL(string: "https://x/1-t.jpg"))
    }

    func test_imageWithCaption_dm_returnsCaption() {
        let m = makeMessage(
            content: "look at this",
            attachments: [att(type: "image", url: "https://x/1.jpg", thumbnailUrl: "https://x/1-t.jpg")]
        )
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "look at this")
        XCTAssertEqual(out.thumbURL, URL(string: "https://x/1-t.jpg"))
    }

    func test_videoOnly_dm_returnsVideoLabel() {
        let m = makeMessage(
            content: "",
            attachments: [att(type: "video", url: "https://x/v.mp4", thumbnailUrl: "https://x/v-t.jpg")]
        )
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "🎥 Video")
    }

    func test_fileOnly_dm_returnsFileLabel() {
        let m = makeMessage(
            content: "",
            attachments: [att(type: "file", url: "https://x/r.pdf", filename: "report.pdf")]
        )
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "📎 report.pdf")
    }

    func test_forward_structured_dm_addsArrowPrefix() {
        let m = makeMessage(content: "look at this", forwardedFromOriginalAuthor: "alice")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "↪ @alice: look at this")
    }

    func test_forward_legacyPrefix_isParsedAndStripped() {
        // No structured field; relies on legacy `> Forwarded from @user\n\n` parsing
        let m = makeMessage(content: "> Forwarded from @alice\n\nlook at this")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "↪ @alice: look at this")
    }

    func test_group_addsSenderPrefix() {
        let m = makeMessage(content: "hello")
        let out = MessagePreviewFormatter.format(message: m, isGroup: true, senderLogin: "bob")
        XCTAssertEqual(out.text, "bob: hello")
    }

    func test_group_forward_addsBothPrefixes() {
        let m = makeMessage(content: "hi", forwardedFromOriginalAuthor: "carol")
        let out = MessagePreviewFormatter.format(message: m, isGroup: true, senderLogin: "bob")
        XCTAssertEqual(out.text, "bob: ↪ @carol: hi")
    }

    func test_emptyMessage_returnsEmpty() {
        let m = makeMessage(content: "")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "")
    }

    // MARK: - Helpers

    private func makeMessage(
        content: String,
        attachments: [MessageAttachment]? = nil,
        forwardedFromOriginalAuthor: String? = nil
    ) -> Message {
        Message.testFixture(
            content: content,
            attachments: attachments,
            forwardedFromOriginalAuthor: forwardedFromOriginalAuthor
        )
    }

    private func att(
        type: String,
        url: String,
        thumbnailUrl: String? = nil,
        filename: String? = nil
    ) -> MessageAttachment {
        MessageAttachment(
            attachment_id: nil,
            url: url,
            type: type,
            filename: filename,
            mime_type: nil,
            width: nil,
            height: nil,
            duration_seconds: nil,
            thumbnail_url: thumbnailUrl
        )
    }
}

import XCTest
import UIKit

final class PasteImageFromClipboardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        UIPasteboard.general.items = []  // reset between tests
    }

    /// T1: image-only clipboard → Cmd+V opens the ImageSendPreview sheet.
    func testPasteImageOpensPreviewSheet() throws {
        UIPasteboard.general.image = UIImage(data: PasteboardFixture.screenshotPNGData())

        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)

        app.textViews["composer"].firstMatch.typeKey("v", modifierFlags: .command)

        let preview = app.images["paste-preview-image"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3),
                      "ImageSendPreview did not appear after Cmd+V on image clipboard")
    }

    /// T2: text-only clipboard → Cmd+V inserts text into composer; no sheet.
    func testPasteTextInsertsIntoComposer() throws {
        UIPasteboard.general.string = "hello world"

        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)

        let composer = app.textViews["composer"].firstMatch
        // Clear any pre-existing draft so the equality assertion is deterministic.
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])

        composer.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(composer.value as? String, "hello world")
        XCTAssertFalse(app.images["paste-preview-image"].waitForExistence(timeout: 1),
                       "Text-only paste should not open ImageSendPreview")
    }
}

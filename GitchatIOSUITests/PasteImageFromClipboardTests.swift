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
}

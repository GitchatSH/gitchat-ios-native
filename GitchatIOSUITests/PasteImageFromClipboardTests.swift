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
        composer.clearText()
        composer.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(composer.value as? String, "hello world")
        XCTAssertFalse(app.images["paste-preview-image"].waitForExistence(timeout: 1),
                       "Text-only paste should not open ImageSendPreview")
    }

    /// T3: image+text clipboard → Cmd+V inserts only text; no sheet (Telegram).
    func testPasteImagePlusText_OnlyTextNoSheet() throws {
        let pngData = PasteboardFixture.screenshotPNGData()
        UIPasteboard.general.items = [[
            "public.utf8-plain-text": "caption only",
            "public.png": pngData
        ]]

        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)

        let composer = app.textViews["composer"].firstMatch
        composer.clearText()
        composer.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(composer.value as? String, "caption only")
        XCTAssertFalse(app.images["paste-preview-image"].waitForExistence(timeout: 1),
                       "Image+text paste should not open the sheet — text-only fallback expected")
    }
}

import XCTest

final class GuestModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_cold_launch_unauthed_shows_GuestTabView() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()
        // Tab bar items
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 5),
                      "Guest cold launch must show Discover tab")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists,
                      "Guest cold launch must show Search tab")
        XCTAssertFalse(app.tabBars.buttons["Chats"].exists,
                       "Guest must not see Chats")
        // Sign-in button in trailing toolbar of Discover stack
        XCTAssertTrue(app.navigationBars.buttons["Sign in"].exists,
                      "Guest must have Sign in toolbar button")
    }
}

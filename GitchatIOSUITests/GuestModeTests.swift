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

    func test_tap_wave_on_profile_shows_signin_prompt_sheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tj")
        app.buttons["Open profile"].tap()

        let waveButton = app.buttons["Wave"]
        XCTAssertTrue(waveButton.waitForExistence(timeout: 8),
                      "Profile load must surface Wave button")
        waveButton.tap()

        XCTAssertTrue(app.staticTexts["Sign in to wave at @tj"]
                        .waitForExistence(timeout: 3),
                      "Tapping Wave on a profile while guest must show SignInPromptSheet")
        XCTAssertTrue(app.buttons["Sign in with GitHub"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists)
    }
}

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

    func test_guest_discover_does_not_show_subtab_picker_or_search_bar() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()

        // Wait for the Discover tab to mount.
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 5))

        // The segmented picker should NOT exist for guests.
        XCTAssertFalse(app.segmentedControls.firstMatch.exists,
                       "Guest must not see the People/Teams sub-tab picker")

        // The .searchable bar should NOT exist for guests.
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "Guest must not see the search bar in Discover")
    }

    // NOTE: A `test_guest_tap_trending_person_pushes_profile_with_wave_button`
    // test was drafted alongside this fix to verify that trending-people rows
    // are tappable for guests, but it was dropped before commit because
    // `https://api-dev.gitstar.ai/api/v1/trending/people` is consistently
    // returning 503 from the dev BE at the moment of writing — the section
    // header never renders because `vm.trendingPeople` is empty, so the
    // tap-and-push assertion never runs. The fix itself (NavigationLink
    // wrapping in `DiscoverGuestList`) is exercised in code via `xcodebuild
    // build` and verified by inspection; once dev BE is healthy the test
    // should be reinstated verbatim from the plan. Do NOT mock the data
    // source here — this suite intentionally hits the real BE to catch
    // env/contract drift.
}

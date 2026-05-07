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
        app.launchArguments += [
            "-uiTest", "-uiTestUnauthed",
            "-debug.apiBaseURL", "http://localhost:3000/api/v1"
        ]
        app.launch()

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tj")
        app.buttons["Open profile"].tap()

        // ProfileView fetches /user/tj from local BE. Wave CTA renders
        // because loadFollowStatus synthesises non-mutual for guests
        // (commit ec78644).
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

    func test_cancel_prompt_stays_on_profile() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTest", "-uiTestUnauthed",
            "-debug.apiBaseURL", "http://localhost:3000/api/v1"
        ]
        app.launch()

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tj")
        app.buttons["Open profile"].tap()

        let waveButton = app.buttons["Wave"]
        XCTAssertTrue(waveButton.waitForExistence(timeout: 8))
        waveButton.tap()

        // Sheet appears; tap Not now instead of GitHub.
        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 3),
                      "Sheet must show Not now button")
        notNow.tap()

        // Sheet dismisses. We should still be on the guest profile —
        // Wave button reappears (same view, sheet closed), and the
        // guest tab bar (Discover/Search only) is still present.
        XCTAssertTrue(waveButton.waitForExistence(timeout: 3),
                      "After dismissing prompt, Wave button must still be visible (still on profile)")
        XCTAssertTrue(app.tabBars.buttons["Discover"].exists,
                      "Guest tab bar must still be in place — no shell swap")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.tabBars.buttons["Chats"].exists,
                       "MainTabView must NOT have replaced GuestTabView")
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

    func test_signout_from_MainTabView_lands_on_GuestTabView() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestPrimeToken"]
        app.launch()

        // Cold launch as authed → MainTabView with 5 tabs.
        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5),
                      "Primed-token launch must show MainTabView (Chats tab)")

        // Navigate to Me tab → gear icon → Settings sheet.
        let meTab = app.tabBars.buttons["Me"]
        XCTAssertTrue(meTab.exists, "Me tab must be reachable")
        meTab.tap()

        // The gear toolbar item exposes accessibilityLabel "Settings".
        let settingsButton = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5),
                      "Settings (gear) button must be reachable from Me tab")
        settingsButton.tap()

        // Inside SettingsView, the "Sign out" row sits near the bottom of
        // a List; scroll it into view before tapping. Use the first
        // table/collection view as the scrollable container — SwiftUI's
        // List on iOS 16+ surfaces as either depending on version.
        let scrollable = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        XCTAssertTrue(scrollable.waitForExistence(timeout: 5),
                      "Settings list must be on screen")
        scrollable.swipeUp()
        scrollable.swipeUp()

        // Match the destructive "Sign out" row. The button label contains
        // a Text("Sign out") so the button is identifiable by that label.
        let signOutButton = app.buttons["Sign out"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 5),
                      "Sign out button must be reachable from Settings")
        signOutButton.tap()

        // Sign-out flow surfaces a confirmation alert with a destructive
        // "Sign out" button.
        let confirmButton = app.alerts.buttons["Sign out"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3),
                      "Sign-out confirmation alert must surface")
        confirmButton.tap()

        // After sign-out, RootView re-renders to GuestTabView. Tab bar
        // collapses to 2 tabs (Discover + Search). MainTabView's
        // "Chats" tab MUST be gone.
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 5),
                      "After sign-out, Discover tab must be visible")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists,
                      "After sign-out, Search tab must be visible")
        XCTAssertFalse(app.tabBars.buttons["Chats"].exists,
                       "After sign-out, Chats tab must be gone (we're guest now)")
    }

    func test_invite_deeplink_join_shows_signin_prompt() throws {
        // The local BE must recognise this invite code. If it doesn't
        // exist, skip — this is intentionally a fragile fixture-bound
        // test; the value comes from the dev / local seed data.
        // Override via UITEST_INVITE_CODE env var (e.g.
        // `UITEST_INVITE_CODE=abc123 xcodebuild test ...`).
        let envCode = ProcessInfo.processInfo.environment["UITEST_INVITE_CODE"]
        let code = envCode ?? "uitest-invite-dev"

        // Precheck: hit the local BE to verify the code is valid before
        // bothering with the UI.
        let url = URL(string: "http://localhost:3000/api/v1/messages/conversations/join/\(code)")!
        let (_, response) = try awaitData(from: url)
        let http = response as? HTTPURLResponse
        try XCTSkipUnless(http?.statusCode == 200,
                          "Skipping invite UI test — local BE doesn't recognise code '\(code)'. Seed an invite or pass UITEST_INVITE_CODE=<code>.")

        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTest", "-uiTestUnauthed",
            "-debug.apiBaseURL", "http://localhost:3000/api/v1",
            "-uiTestInviteCode", code
        ]
        app.launch()

        // Sheet should appear automatically because AppRouter primed
        // pendingInviteCode at init.
        let joinButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Join'")).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 6),
                      "Join button must render after invite preview loads")
        joinButton.tap()

        XCTAssertTrue(app.staticTexts["Sign in to join the group"]
                        .waitForExistence(timeout: 3),
                      "Tapping Join while guest must show SignInPromptSheet for .invite")
        XCTAssertTrue(app.buttons["Sign in with GitHub"].exists)
    }

    /// Synchronous wrapper around URLSession.dataTask — used in setUp
    /// only for cheap precheck.
    private func awaitData(from url: URL) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var data = Data()
        var response: URLResponse?
        var error: Error?
        URLSession.shared.dataTask(with: url) { d, r, e in
            if let d { data = d }
            response = r
            error = e
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        if let error { throw error }
        guard let response else { throw URLError(.badServerResponse) }
        return (data, response)
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

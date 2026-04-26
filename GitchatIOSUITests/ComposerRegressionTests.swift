import XCTest

final class ComposerRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// T7 (iOS only): composer grows from 1 to ≥4 lines as user types
    /// newlines. Catalyst is excluded because bare Return submits there.
    #if !targetEnvironment(macCatalyst)
    func testComposerMultilineGrowth() throws {
        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)
        let composer = app.textViews["composer"].firstMatch
        composer.clearText()

        let initialFrame = composer.frame
        // Use Shift+Return to force newline regardless of platform — Shift
        // is a no-op on iOS but keeps the test single-codepath.
        composer.typeText("a")
        composer.typeKey(.enter, modifierFlags: .shift)
        composer.typeText("b")
        composer.typeKey(.enter, modifierFlags: .shift)
        composer.typeText("c")
        composer.typeKey(.enter, modifierFlags: .shift)
        composer.typeText("d")

        let grownFrame = composer.frame
        XCTAssertGreaterThan(grownFrame.height, initialFrame.height + 30,
            "Composer should auto-grow with multi-line content. " +
            "initial=\(initialFrame.height) grown=\(grownFrame.height)")
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// T8 (Catalyst): bare Return calls onSubmit, sends the message,
    /// composer is cleared.
    func testCatalystReturnSubmits() throws {
        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)
        let composer = app.textViews["composer"].firstMatch
        composer.clearText()

        composer.typeText("hi")
        composer.typeKey(.enter, modifierFlags: [])

        // After submit, draft clears (vm.draft is bound; UITextView reflects)
        let cleared = NSPredicate(format: "value == ''")
        expectation(for: cleared, evaluatedWith: composer, handler: nil)
        waitForExpectations(timeout: 3)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// T9 (Catalyst): Shift+Return inserts \n into composer, no submit.
    func testCatalystShiftReturnNewline() throws {
        let app = XCUIApplication()
        app.launchForUITests()
        try ChatNav.openFirstChat(app)
        let composer = app.textViews["composer"].firstMatch
        composer.clearText()

        composer.typeText("hi")
        composer.typeKey(.enter, modifierFlags: .shift)
        composer.typeText("there")

        XCTAssertEqual(composer.value as? String, "hi\nthere")
    }
    #endif
}

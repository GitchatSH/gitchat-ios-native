import XCTest

extension XCUIApplication {
    /// Launches the app with deterministic UI-test arguments. Production
    /// code that needs to short-circuit (e.g. push notification opt-in
    /// prompts, network-dependent splashes) should check
    /// `ProcessInfo.processInfo.arguments.contains("-uiTest")`.
    func launchForUITests() {
        launchArguments += ["-uiTest"]
        launch()
    }
}

extension XCUIElement {
    /// Clears the receiver's text by selecting all (Cmd+A) and pressing
    /// Delete. Standard XCUITest idiom for normalizing UITextField /
    /// UITextView pre-state when an exact-equality assertion follows.
    /// The element must be focused (call `.tap()` first).
    func clearText() {
        typeKey("a", modifierFlags: .command)
        typeKey(.delete, modifierFlags: [])
    }
}

enum PasteboardFixture {
    /// Loads `test-screenshot.png` from the test bundle as `UIImage`-
    /// equivalent data. Returns the raw PNG bytes — callers should
    /// decode via `UIImage(data:)` if they need a UIImage instance.
    static func screenshotPNGData() -> Data {
        let url = Bundle(for: PasteboardFixtureBundleAnchor.self)
            .url(forResource: "test-screenshot", withExtension: "png")
        guard let url, let data = try? Data(contentsOf: url) else {
            fatalError("test-screenshot.png missing from GitchatIOSUITests Resources")
        }
        return data
    }
}
final class PasteboardFixtureBundleAnchor {}

enum ChatNav {
    /// Navigates from app launch to a chat detail view with the
    /// composer focused. Skips (not fails) when the simulator state is
    /// not test-ready (signed out, no conversations, or auth wall up).
    /// Skips give a clear next-action message instead of a confusing
    /// element-not-found assertion failure.
    static func openFirstChat(_ app: XCUIApplication) throws {
        let firstRow = app.cells.element(boundBy: 0)
        try XCTSkipUnless(firstRow.waitForExistence(timeout: 8),
            "Simulator not test-ready: sign in once and ensure ≥1 conversation exists, then re-run.")
        firstRow.tap()
        let composer = app.textViews["composer"].firstMatch
        try XCTSkipUnless(composer.waitForExistence(timeout: 5),
            "Composer not found after opening first conversation.")
        composer.tap()
    }
}

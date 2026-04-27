import XCTest

final class SmokeTests: XCTestCase {
    func testHarnessBuildsAndLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest"]
        app.launch()
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
    }
}

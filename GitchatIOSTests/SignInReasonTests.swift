import XCTest
@testable import Gitchat

final class SignInReasonTests: XCTestCase {

    func test_titles_per_case() {
        XCTAssertEqual(SignInReason.wave(login: "ethan").title,
                       "Sign in to wave at @ethan")
        XCTAssertEqual(SignInReason.dm(login: "ethan").title,
                       "Sign in to message @ethan")
        XCTAssertEqual(SignInReason.follow(login: "ethan").title,
                       "Sign in to follow @ethan")
        XCTAssertEqual(SignInReason.post.title,
                       "Sign in to post")
        XCTAssertEqual(SignInReason.react.title,
                       "Sign in to react")
        XCTAssertEqual(SignInReason.invite.title,
                       "Sign in to join the group")
    }
}

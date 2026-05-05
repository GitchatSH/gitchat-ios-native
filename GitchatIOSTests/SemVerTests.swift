import XCTest
@testable import Gitchat

final class SemVerTests: XCTestCase {

    func test_parses_dotted_triple() {
        let v = SemVer("1.2.3")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
    }

    func test_parses_two_components_defaults_patch_to_zero() {
        XCTAssertEqual(SemVer("1.2")?.patch, 0)
    }

    func test_parses_one_component_defaults_minor_and_patch() {
        let v = SemVer("3")
        XCTAssertEqual(v?.major, 3)
        XCTAssertEqual(v?.minor, 0)
        XCTAssertEqual(v?.patch, 0)
    }

    func test_strips_v_prefix() {
        XCTAssertEqual(SemVer("v1.2.3")?.major, 1)
    }

    func test_drops_prerelease_suffix() {
        XCTAssertEqual(SemVer("1.2.3-beta.1")?.patch, 3)
    }

    func test_drops_build_metadata() {
        XCTAssertEqual(SemVer("1.2.3+build.42")?.patch, 3)
    }

    func test_returns_nil_on_non_numeric_major() {
        XCTAssertNil(SemVer("not-a-version"))
    }

    func test_returns_nil_on_empty_input() {
        XCTAssertNil(SemVer(""))
    }

    func test_returns_nil_on_non_numeric_minor() {
        XCTAssertNil(SemVer("1.x.0"))
    }

    func test_returns_nil_on_non_numeric_patch() {
        XCTAssertNil(SemVer("1.0.x"))
    }

    func test_returns_nil_on_empty_inner_component() {
        // "1..3" must not silently parse as 1.0.0 or 1.3.x — present-but-empty
        // components are non-numeric and must fail.
        XCTAssertNil(SemVer("1..3"))
    }

    func test_strips_v_prefix_and_prerelease() {
        let v = SemVer("v1.2.3-beta.1")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
    }

    func test_compare_is_numeric_not_lexicographic() {
        XCTAssertTrue(SemVer("1.9.0")! < SemVer("1.10.0")!)
    }

    func test_equal_versions_are_not_less() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer("1.2.3"))
        XCTAssertFalse(SemVer("1.2.3")! < SemVer("1.2.3")!)
    }

    func test_patch_compare() {
        XCTAssertTrue(SemVer("1.2.3")! < SemVer("1.2.4")!)
    }

    func test_minor_dominates_patch() {
        XCTAssertTrue(SemVer("1.2.99")! < SemVer("1.3.0")!)
    }

    func test_major_dominates_minor() {
        XCTAssertTrue(SemVer("1.99.99")! < SemVer("2.0.0")!)
    }
}

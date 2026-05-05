# In-App Update Gate — MVP (PR #1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the soft-prompt path of the in-app update gate per `docs/superpowers/specs/2026-05-05-in-app-update-gate-mvp-design.md`. After this PR, the app detects when a newer version exists, shows a top banner, and routes "Update now" into an in-app `SKStoreProductViewController`. Force-update + 426 + TestFlight stay deferred to PR #2.

**Architecture:** Five new files under `GitchatIOS/Core/AppUpdate/` (model, SemVer, fetcher protocol, checker, store sheet, banner) plus call-site wiring in `APIClient.swift`, `PushManager.swift`, and `RootView.swift`. The checker is an `@MainActor ObservableObject` that owns a 3-state machine (`.unknown` / `.upToDate` / `.updateAvailable`), with `UserDefaults`-backed throttle (1×/hr foreground) and 24h snooze keyed to version. All collaborators (`VersionFetcher`, `UserDefaults`, `now()`, `currentVersion()`) are injected so the checker is unit-testable.

**Tech Stack:** Swift 5.9, SwiftUI, StoreKit (`SKStoreProductViewController`), XCTest. Module name is `Gitchat` (not `GitchatIOS`). Tests run via `xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:GitchatIOSTests/<TestClass>`.

**Pre-flight:**
- On branch `feat/in-app-update-gate-mvp` (already created from `main`).
- Spec already committed (`849d9fc`).
- BE contract verified live on 2026-05-05 against `https://api-dev.gitchat.sh/api/v1/app/version?platform=ios`.

---

## File Structure

| File | Role | Status |
|---|---|---|
| `GitchatIOS/Core/AppUpdate/AppVersionManifest.swift` | Decodable response model | CREATE |
| `GitchatIOS/Core/AppUpdate/SemVer.swift` | Parser + `Comparable` | CREATE |
| `GitchatIOS/Core/AppUpdate/VersionFetcher.swift` | Fetch protocol + production wrapper | CREATE |
| `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` | `@MainActor ObservableObject`, state machine | CREATE |
| `GitchatIOS/Core/AppUpdate/AppStoreSheet.swift` | `UIViewControllerRepresentable` for `SKStoreProductViewController` | CREATE |
| `GitchatIOS/Core/AppUpdate/UpdateBanner.swift` | SwiftUI top banner | CREATE |
| `GitchatIOS/Core/Networking/APIClient.swift` | Add `fetchAppVersionManifest()` | MODIFY |
| `GitchatIOS/Core/PushManager.swift` | Add `app_update` switch case | MODIFY |
| `GitchatIOS/App/RootView.swift` | Wire updater, banner overlay, store sheet, scenePhase trigger | MODIFY |
| `GitchatIOSTests/AppVersionManifestDecodingTests.swift` | Decoding test against live JSON | CREATE |
| `GitchatIOSTests/SemVerTests.swift` | Parser + comparator tests | CREATE |
| `GitchatIOSTests/AppUpdateCheckerStateTests.swift` | State machine tests | CREATE |
| `GitchatIOSTests/AppUpdateCheckerThrottleTests.swift` | Throttle tests | CREATE |
| `GitchatIOSTests/AppUpdateCheckerSnoozeTests.swift` | Snooze tests | CREATE |

After every task that adds a new `.swift` file, run `xcodegen generate` and verify the file landed in the project (`grep -c <File>.swift GitchatIOS.xcodeproj/project.pbxproj` must be `> 0`).

Reference (read-only, do **not** copy verbatim): `origin/feat/in-app-update-gate` has lngdao's prior cuts of `SemVer.swift` and `AppStoreSheet.swift` — use as sanity check, not source.

---

## Task 1: `AppVersionManifest` model + decoding test

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/AppVersionManifest.swift`
- Create: `GitchatIOSTests/AppVersionManifestDecodingTests.swift`

- [ ] **Step 1.1: Write the failing test**

Create `GitchatIOSTests/AppVersionManifestDecodingTests.swift`:

```swift
import XCTest
@testable import Gitchat

final class AppVersionManifestDecodingTests: XCTestCase {

    // Captured live from
    // GET https://api-dev.gitchat.sh/api/v1/app/version?platform=ios
    // on 2026-05-05.
    private let liveResponseJSON = """
    {
      "data": {
        "latestVersion": "1.0.4",
        "releaseNotes": "Minor bugs fixed",
        "releasedAt": "2026-04-23T21:15:52Z",
        "storeUrl": "https://apps.apple.com/us/app/gitchat/id6762181976?uo=4",
        "appStoreId": "6762181976",
        "minimumSupportedVersion": "1.0.0",
        "isForceUpdate": false
      },
      "statusCode": 200,
      "message": "Success"
    }
    """

    func test_decodes_inside_envelope() throws {
        let data = liveResponseJSON.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<AppVersionManifest>.self, from: data)
        let manifest = try XCTUnwrap(envelope.data)
        XCTAssertEqual(manifest.latestVersion, "1.0.4")
        XCTAssertEqual(manifest.releaseNotes, "Minor bugs fixed")
        XCTAssertEqual(manifest.appStoreId, "6762181976")
        XCTAssertEqual(manifest.storeUrl.absoluteString, "https://apps.apple.com/us/app/gitchat/id6762181976?uo=4")
        XCTAssertEqual(manifest.minimumSupportedVersion, "1.0.0")
        XCTAssertEqual(manifest.isForceUpdate, false)
    }

    func test_releaseNotes_optional_when_missing() throws {
        let json = """
        {"data":{"latestVersion":"2.0.0","storeUrl":"https://example.com/app","appStoreId":"1","minimumSupportedVersion":"1.0.0","isForceUpdate":false},"statusCode":200,"message":"OK"}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<AppVersionManifest>.self, from: json)
        let manifest = try XCTUnwrap(envelope.data)
        XCTAssertNil(manifest.releaseNotes)
    }
}
```

- [ ] **Step 1.2: Create the model file**

Create `GitchatIOS/Core/AppUpdate/AppVersionManifest.swift`:

```swift
import Foundation

struct AppVersionManifest: Decodable, Equatable {
    let latestVersion: String
    let releaseNotes: String?
    /// Raw ISO8601 string. Kept as `String` (not `Date`) in MVP to avoid
    /// touching the global `JSONDecoder` strategy used by other endpoints.
    let releasedAt: String?
    let storeUrl: URL
    let appStoreId: String
    /// Unused in MVP; parsed so PR #2 force-update logic doesn't have to
    /// touch the BE-contract layer.
    let minimumSupportedVersion: String
    /// Unused in MVP; parsed so PR #2 force-update logic doesn't have to
    /// touch the BE-contract layer.
    let isForceUpdate: Bool
}
```

- [ ] **Step 1.3: Regenerate Xcode project**

Run:
```bash
xcodegen generate
grep -c "AppVersionManifest.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "AppVersionManifestDecodingTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Both `grep` counts must be `> 0`.

- [ ] **Step 1.4: Run the tests, expect PASS**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppVersionManifestDecodingTests
```
Expected: `Test Suite 'AppVersionManifestDecodingTests' passed`, 2 tests.

- [ ] **Step 1.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/AppVersionManifest.swift \
        GitchatIOSTests/AppVersionManifestDecodingTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): AppVersionManifest model + decoding tests (refs #43, #66)"
```

---

## Task 2: `SemVer` parser + tests

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/SemVer.swift`
- Create: `GitchatIOSTests/SemVerTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `GitchatIOSTests/SemVerTests.swift`:

```swift
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

    func test_returns_nil_on_garbage() {
        XCTAssertNil(SemVer("not-a-version"))
        XCTAssertNil(SemVer(""))
    }

    func test_compare_is_numeric_not_lexicographic() {
        // Lexicographic compare would say "1.10.0" < "1.9.0"; we must not.
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
```

- [ ] **Step 2.2: Create the parser**

Create `GitchatIOS/Core/AppUpdate/SemVer.swift`:

```swift
import Foundation

struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Lenient parser: strips a leading `v`, drops any `-prerelease` or
    /// `+build` suffix, and tolerates 1- or 2-component inputs by defaulting
    /// missing components to 0. Returns `nil` only when the major component
    /// is absent or non-numeric.
    init?(_ raw: String) {
        var trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        if let dash = trimmed.firstIndex(of: "-") { trimmed = String(trimmed[..<dash]) }
        if let plus = trimmed.firstIndex(of: "+") { trimmed = String(trimmed[..<plus]) }

        let parts = trimmed.split(separator: ".").map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 2.3: Regenerate + verify project membership**

```bash
xcodegen generate
grep -c "SemVer.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "SemVerTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Both `> 0`.

- [ ] **Step 2.4: Run tests, expect PASS**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/SemVerTests
```
Expected: 12 tests passed.

- [ ] **Step 2.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/SemVer.swift \
        GitchatIOSTests/SemVerTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): SemVer parser + comparator (refs #43, #66)"
```

---

## Task 3: `APIClient.fetchAppVersionManifest()` + `VersionFetcher` protocol

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/VersionFetcher.swift`
- Modify: `GitchatIOS/Core/Networking/APIClient.swift` (add new method, location: end of "Feature endpoints" region)

No new tests in this task — the decode contract is already proven by Task 1, and the rest is plumbing. The protocol exists solely to keep `AppUpdateChecker` testable in Tasks 4–6.

- [ ] **Step 3.1: Add the APIClient method**

In `GitchatIOS/Core/Networking/APIClient.swift`, append after the last existing endpoint method (right before the closing brace of the `APIClient` class):

```swift
    // MARK: - App version

    /// `GET /app/version?platform=ios`. No auth. Used by `AppUpdateChecker`.
    func fetchAppVersionManifest() async throws -> AppVersionManifest {
        return try await request(
            "app/version",
            method: "GET",
            query: [URLQueryItem(name: "platform", value: "ios")],
            requireAuth: false
        )
    }
```

- [ ] **Step 3.2: Create the fetcher protocol + production wrapper**

Create `GitchatIOS/Core/AppUpdate/VersionFetcher.swift`:

```swift
import Foundation

protocol VersionFetcher {
    func fetch() async throws -> AppVersionManifest
}

struct APIClientVersionFetcher: VersionFetcher {
    func fetch() async throws -> AppVersionManifest {
        try await APIClient.shared.fetchAppVersionManifest()
    }
}
```

- [ ] **Step 3.3: Regenerate + verify**

```bash
xcodegen generate
grep -c "VersionFetcher.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3.4: Re-run prior tests to confirm no regressions**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppVersionManifestDecodingTests \
  -only-testing:GitchatIOSTests/SemVerTests
```
Expected: all pass.

- [ ] **Step 3.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/VersionFetcher.swift \
        GitchatIOS/Core/Networking/APIClient.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): APIClient.fetchAppVersionManifest + VersionFetcher protocol (refs #43, #66)"
```

---

## Task 4: `AppUpdateChecker` skeleton + state-transition tests

This task introduces the checker with **no throttle and no snooze logic** — pure compare-and-emit. Throttle is added in Task 5; snooze in Task 6.

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`
- Create: `GitchatIOSTests/AppUpdateCheckerStateTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Create `GitchatIOSTests/AppUpdateCheckerStateTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerStateTests: XCTestCase {

    private struct StubFetcher: VersionFetcher {
        let result: Result<AppVersionManifest, Error>
        func fetch() async throws -> AppVersionManifest {
            switch result {
            case .success(let m): return m
            case .failure(let e): throw e
            }
        }
    }

    private func makeManifest(latest: String, force: Bool = false) -> AppVersionManifest {
        AppVersionManifest(
            latestVersion: latest,
            releaseNotes: "Notes",
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: force
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_latest_greater_than_current_emits_updateAvailable() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "1.2.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("expected .updateAvailable, got \(checker.state)")
        }
        XCTAssertEqual(info.latestRaw, "1.2.0")
        XCTAssertEqual(info.releaseNotes, "Notes")
        XCTAssertEqual(info.appStoreId, "1")
    }

    func test_latest_equal_to_current_emits_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "1.1.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_latest_less_than_current_emits_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "0.9.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_fetch_failure_leaves_state_unchanged() async {
        struct E: Error {}
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .failure(E())),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        XCTAssertEqual(checker.state, .unknown)
        await checker.check()
        XCTAssertEqual(checker.state, .unknown)  // unchanged
    }
}
```

- [ ] **Step 4.2: Create the checker (skeleton — no throttle, no snooze yet)**

Create `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`:

```swift
import Foundation
import SwiftUI

@MainActor
final class AppUpdateChecker: ObservableObject {

    static let shared = AppUpdateChecker(
        fetcher: APIClientVersionFetcher(),
        defaults: .standard,
        currentVersion: { Config.appVersion },
        now: { Date() }
    )

    @Published private(set) var state: UpdateState = .unknown

    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)
    }

    struct VersionInfo: Equatable {
        let latest: SemVer
        let latestRaw: String
        let releaseNotes: String?
        let storeUrl: URL
        let appStoreId: String
    }

    private let fetcher: VersionFetcher
    private let defaults: UserDefaults
    private let currentVersion: () -> String
    private let now: () -> Date

    init(
        fetcher: VersionFetcher,
        defaults: UserDefaults,
        currentVersion: @escaping () -> String,
        now: @escaping () -> Date
    ) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
    }

    /// Cold-launch and foreground entry point. `force == true` is reserved
    /// for push-tap re-checks (Task 5 wires the throttle bypass).
    func check(force: Bool = false) async {
        do {
            let manifest = try await fetcher.fetch()
            apply(manifest: manifest)
        } catch {
            NSLog("[AppUpdateChecker] fetch failed: \(error)")
            // leave state unchanged on transient failure
        }
    }

    private func apply(manifest: AppVersionManifest) {
        guard
            let latest = SemVer(manifest.latestVersion),
            let current = SemVer(currentVersion())
        else {
            state = .unknown
            return
        }
        if !(current < latest) {
            state = .upToDate
            return
        }
        state = .updateAvailable(VersionInfo(
            latest: latest,
            latestRaw: manifest.latestVersion,
            releaseNotes: manifest.releaseNotes,
            storeUrl: manifest.storeUrl,
            appStoreId: manifest.appStoreId
        ))
    }
}
```

- [ ] **Step 4.3: Regenerate + verify**

```bash
xcodegen generate
grep -c "AppUpdateChecker.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "AppUpdateCheckerStateTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```

- [ ] **Step 4.4: Run tests, expect PASS**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerStateTests
```
Expected: 4 tests passed.

- [ ] **Step 4.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift \
        GitchatIOSTests/AppUpdateCheckerStateTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): AppUpdateChecker — state machine skeleton + tests (refs #43, #66)"
```

---

## Task 5: Throttle (1×/hr foreground, force bypass)

**Files:**
- Modify: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` (add throttle to `check()`)
- Create: `GitchatIOSTests/AppUpdateCheckerThrottleTests.swift`

- [ ] **Step 5.1: Write the failing tests**

Create `GitchatIOSTests/AppUpdateCheckerThrottleTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerThrottleTests: XCTestCase {

    private final class CountingFetcher: VersionFetcher {
        var calls = 0
        var manifest: AppVersionManifest = .init(
            latestVersion: "2.0.0",
            releaseNotes: nil,
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: false
        )
        func fetch() async throws -> AppVersionManifest { calls += 1; return manifest }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerThrottleTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_first_check_always_runs() async {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        await checker.check()
        XCTAssertEqual(fetcher.calls, 1)
    }

    func test_second_check_within_one_hour_is_throttled() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(30 * 60)  // 30 min later
        await checker.check()
        XCTAssertEqual(fetcher.calls, 1, "second call within 1h must be skipped")
    }

    func test_check_after_one_hour_runs_again() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(60 * 60 + 1)  // just past 1h
        await checker.check()
        XCTAssertEqual(fetcher.calls, 2)
    }

    func test_force_bypasses_throttle() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(30)  // 30s later
        await checker.check(force: true)
        XCTAssertEqual(fetcher.calls, 2, "force=true must ignore throttle")
    }
}
```

- [ ] **Step 5.2: Add throttle logic to `check()`**

In `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`, add the throttle key constants alongside the existing properties (just after `private let now: () -> Date`):

```swift
    private static let kLastChecked = "appUpdate.lastCheckedAt"
    private static let throttleInterval: TimeInterval = 60 * 60   // 1 hour
```

Then replace the body of `check(force:)` with:

```swift
    func check(force: Bool = false) async {
        if !force,
           let last = defaults.object(forKey: Self.kLastChecked) as? Date,
           now().timeIntervalSince(last) < Self.throttleInterval {
            return
        }
        defaults.set(now(), forKey: Self.kLastChecked)
        do {
            let manifest = try await fetcher.fetch()
            apply(manifest: manifest)
        } catch {
            NSLog("[AppUpdateChecker] fetch failed: \(error)")
        }
    }
```

- [ ] **Step 5.3: Regenerate + verify**

```bash
xcodegen generate
grep -c "AppUpdateCheckerThrottleTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```

- [ ] **Step 5.4: Run all checker tests, expect PASS**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerStateTests \
  -only-testing:GitchatIOSTests/AppUpdateCheckerThrottleTests
```
Expected: 8 tests passed total (4 state + 4 throttle).

- [ ] **Step 5.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift \
        GitchatIOSTests/AppUpdateCheckerThrottleTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): AppUpdateChecker — 1h throttle + force bypass (refs #43, #66)"
```

---

## Task 6: Snooze (24h, version-keyed, immediate state flip)

**Files:**
- Modify: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` (add `snooze()`, snooze keys, snooze filter in `apply`)
- Create: `GitchatIOSTests/AppUpdateCheckerSnoozeTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Create `GitchatIOSTests/AppUpdateCheckerSnoozeTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerSnoozeTests: XCTestCase {

    private final class MutableFetcher: VersionFetcher {
        var manifest: AppVersionManifest
        init(latest: String) {
            self.manifest = AppVersionManifest(
                latestVersion: latest,
                releaseNotes: nil,
                releasedAt: nil,
                storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
                appStoreId: "1",
                minimumSupportedVersion: "1.0.0",
                isForceUpdate: false
            )
        }
        func fetch() async throws -> AppVersionManifest { manifest }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerSnoozeTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_snooze_immediately_flips_state_to_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
        await checker.check()
        if case .updateAvailable = checker.state { /* ok */ } else {
            return XCTFail("setup: expected updateAvailable")
        }
        checker.snooze()
        XCTAssertEqual(checker.state, .upToDate, "snooze must hide banner immediately")
    }

    func test_snooze_persists_across_recheck_within_24h() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        clock = clock.addingTimeInterval(2 * 60 * 60)        // 2h later
        await checker.check(force: true)                      // bypass throttle
        XCTAssertEqual(checker.state, .upToDate, "still inside 24h snooze; banner should stay hidden")
    }

    func test_snooze_invalidated_when_version_bumps() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let fetcher = MutableFetcher(latest: "2.0.0")
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        // BE bumps version while we're still inside the 24h window.
        clock = clock.addingTimeInterval(60 * 60)
        fetcher.manifest = AppVersionManifest(
            latestVersion: "2.1.0",
            releaseNotes: nil,
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: false
        )
        await checker.check(force: true)
        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("expected banner to re-appear for newer version")
        }
        XCTAssertEqual(info.latestRaw, "2.1.0")
    }

    func test_snooze_expires_after_24h() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        clock = clock.addingTimeInterval(24 * 60 * 60 + 1)   // just past 24h
        await checker.check(force: true)
        if case .updateAvailable = checker.state { /* ok */ } else {
            XCTFail("snooze should have expired")
        }
    }
}
```

- [ ] **Step 6.2: Add snooze logic to the checker**

In `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`, alongside the throttle constants, add:

```swift
    private static let kSnoozedUntil = "appUpdate.snoozedUntil"
    private static let kSnoozedVersion = "appUpdate.snoozedVersion"
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60   // 24 hours
```

Add the public `snooze()` method (place it just below `check`):

```swift
    /// User tapped "Not now" on the banner. Hides the banner now and for
    /// the next 24h — unless BE bumps `latestVersion`, in which case the
    /// next `check()` re-surfaces the banner with the new version.
    func snooze() {
        guard case .updateAvailable(let info) = state else { return }
        defaults.set(now().addingTimeInterval(Self.snoozeInterval), forKey: Self.kSnoozedUntil)
        defaults.set(info.latestRaw, forKey: Self.kSnoozedVersion)
        state = .upToDate
    }
```

Replace `apply(manifest:)`'s `state = .updateAvailable(...)` branch with the snooze-filtering version. The full updated `apply` becomes:

```swift
    private func apply(manifest: AppVersionManifest) {
        guard
            let latest = SemVer(manifest.latestVersion),
            let current = SemVer(currentVersion())
        else {
            state = .unknown
            return
        }
        if !(current < latest) {
            state = .upToDate
            return
        }
        // latest > current — consult snooze before surfacing banner
        if let until = defaults.object(forKey: Self.kSnoozedUntil) as? Date,
           let snoozedVer = defaults.string(forKey: Self.kSnoozedVersion),
           until > now(),
           snoozedVer == manifest.latestVersion {
            state = .upToDate
            return
        }
        state = .updateAvailable(VersionInfo(
            latest: latest,
            latestRaw: manifest.latestVersion,
            releaseNotes: manifest.releaseNotes,
            storeUrl: manifest.storeUrl,
            appStoreId: manifest.appStoreId
        ))
    }
```

- [ ] **Step 6.3: Regenerate + verify**

```bash
xcodegen generate
grep -c "AppUpdateCheckerSnoozeTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```

- [ ] **Step 6.4: Run all checker tests, expect PASS**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerStateTests \
  -only-testing:GitchatIOSTests/AppUpdateCheckerThrottleTests \
  -only-testing:GitchatIOSTests/AppUpdateCheckerSnoozeTests
```
Expected: 12 tests pass total (4 + 4 + 4).

- [ ] **Step 6.5: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift \
        GitchatIOSTests/AppUpdateCheckerSnoozeTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): AppUpdateChecker — 24h snooze, version-keyed (refs #43, #66)"
```

---

## Task 7: `AppStoreSheet` (`SKStoreProductViewController` wrapper)

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/AppStoreSheet.swift`

No tests — `UIViewControllerRepresentable` over a UIKit class. Verified at the smoke-test step (Task 11).

- [ ] **Step 7.1: Create the wrapper**

Create `GitchatIOS/Core/AppUpdate/AppStoreSheet.swift`:

```swift
import StoreKit
import SwiftUI
import UIKit

struct AppStoreSheet: UIViewControllerRepresentable {
    let appStoreId: String
    let fallbackURL: URL

    func makeUIViewController(context: Context) -> SKStoreProductViewController {
        let vc = SKStoreProductViewController()
        vc.delegate = context.coordinator

        #if targetEnvironment(simulator)
        NSLog("[AppStoreSheet] simulator: SKStoreProductViewController is a no-op; would open \(fallbackURL.absoluteString)")
        #else
        let params = [SKStoreProductParameterITunesItemIdentifier: appStoreId]
        vc.loadProduct(withParameters: params) { [fallbackURL] success, _ in
            if !success {
                NSLog("[AppStoreSheet] loadProduct failed; opening fallback URL")
                DispatchQueue.main.async { UIApplication.shared.open(fallbackURL) }
            }
        }
        #endif

        return vc
    }

    func updateUIViewController(_: SKStoreProductViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        func productViewControllerDidFinish(_ vc: SKStoreProductViewController) {
            vc.dismiss(animated: true)
        }
    }
}
```

- [ ] **Step 7.2: Regenerate + build**

```bash
xcodegen generate
grep -c "AppStoreSheet.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7.3: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/AppStoreSheet.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): AppStoreSheet — SKStoreProductViewController SwiftUI wrapper (refs #43, #66)"
```

---

## Task 8: `UpdateBanner` SwiftUI view

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/UpdateBanner.swift`

- [ ] **Step 8.1: Create the banner**

Create `GitchatIOS/Core/AppUpdate/UpdateBanner.swift`:

```swift
import SwiftUI

struct UpdateBanner: View {
    let versionRaw: String
    let notes: String?
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("New version \(versionRaw) available")
                    .font(.subheadline.weight(.semibold))
                if let notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button("Update", action: onUpdate)
                .font(.callout.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss update banner")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

#Preview {
    UpdateBanner(
        versionRaw: "1.4.2",
        notes: "Faster message search and fixes for muted chats.",
        onUpdate: {},
        onDismiss: {}
    )
}
```

- [ ] **Step 8.2: Regenerate + build**

```bash
xcodegen generate
grep -c "UpdateBanner.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8.3: Commit**

```bash
git add GitchatIOS/Core/AppUpdate/UpdateBanner.swift \
        GitchatIOS.xcodeproj/project.pbxproj \
        project.yml
git commit -m "feat(ios): UpdateBanner SwiftUI view (refs #43, #66)"
```

---

## Task 9: Hook `app_update` push into `PushManager`

**Files:**
- Modify: `GitchatIOS/Core/PushManager.swift` (insert one case before the existing `default:` at line 109)

- [ ] **Step 9.1: Add the switch case**

In `GitchatIOS/Core/PushManager.swift`, locate the `wave` case ending at line 108 and insert immediately after it (i.e., right before `default:`):

```swift
        case "app_update":
            // BE broadcasts this when a new release is published.
            // Force-bypass the 1h throttle so the user sees the prompt
            // the moment they open the app from the push.
            Task { @MainActor in
                await AppUpdateChecker.shared.check(force: true)
            }
```

The full switch fragment for orientation (lines 89–109 after edit):

```swift
        case "wave":
            // ... existing wave handling ...
        case "app_update":
            // BE broadcasts this when a new release is published.
            // Force-bypass the 1h throttle so the user sees the prompt
            // the moment they open the app from the push.
            Task { @MainActor in
                await AppUpdateChecker.shared.check(force: true)
            }
        default:
            // ... existing default ...
```

- [ ] **Step 9.2: Build to confirm no regression**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 9.3: Commit**

```bash
git add GitchatIOS/Core/PushManager.swift
git commit -m "feat(ios): PushManager — app_update push triggers AppUpdateChecker (refs #43, #66)"
```

---

## Task 10: Wire into `RootView`

**Files:**
- Modify: `GitchatIOS/App/RootView.swift`

- [ ] **Step 10.1: Add updater state**

In `GitchatIOS/App/RootView.swift`, alongside the existing `@StateObject` declarations (line 12–16 area), add:

```swift
    @StateObject private var updater = AppUpdateChecker.shared
    @State private var showUpdateStoreSheet = false
    @State private var pendingUpdateInfo: AppUpdateChecker.VersionInfo?
```

- [ ] **Step 10.2: Add overlay + sheet + cold-launch task**

Below the existing `.sheet(item: ...)` modifiers and **above** the existing `.onChange(of: scenePhase)` (currently around line 51), add:

```swift
        .overlay(alignment: .top) {
            if case let .updateAvailable(info) = updater.state {
                UpdateBanner(
                    versionRaw: info.latestRaw,
                    notes: info.releaseNotes,
                    onUpdate: {
                        pendingUpdateInfo = info
                        showUpdateStoreSheet = true
                    },
                    onDismiss: { updater.snooze() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: updater.state)
            }
        }
        .sheet(isPresented: $showUpdateStoreSheet) {
            if let info = pendingUpdateInfo {
                AppStoreSheet(appStoreId: info.appStoreId, fallbackURL: info.storeUrl)
            }
        }
        .task { await updater.check() }
```

- [ ] **Step 10.3: Trigger throttled re-check on foreground resume**

The existing `.onChange(of: scenePhase) { phase in ... }` block (~line 51) handles presence + OneSignal resync. Add the updater check at the **end** of that closure, still gated by `phase == .active`:

```swift
        .onChange(of: scenePhase) { phase in
            // ... existing presence + OneSignal logic — DO NOT modify ...

            if phase == .active {
                Task { await updater.check() }
            }
        }
```

> Implementation note: do **not** rewrite the existing closure body. Only append the new `if phase == .active` block at the end.

- [ ] **Step 10.4: Build**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10.5: Run the full test suite to confirm no regression**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests
```
Expected: all GitchatIOSTests pass.

- [ ] **Step 10.6: Commit**

```bash
git add GitchatIOS/App/RootView.swift
git commit -m "feat(ios): RootView — wire AppUpdateChecker (banner + store sheet + scenePhase) (refs #43, #66)"
```

---

## Task 11: End-to-end smoke test on Simulator

This task has **no code changes**. It exercises the full path in a booted simulator and confirms the banner appears, "Update" presents the store sheet (no-op on simulator with logging), and dismiss snoozes.

**Files:** none.

- [ ] **Step 11.1: Boot a simulator and install the local build**

```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Gitchat.app
```

- [ ] **Step 11.2: Force a stale current-version, launch, and watch the log**

The cleanest way to force a `latestVersion > currentVersion` mismatch without touching code is to override `Config.appVersion` via `CFBundleShortVersionString` in the running app's `Info.plist`. Easier path: temporarily edit `Config.appVersion` to return `"0.1.0"` for this verification only.

```bash
# In a separate terminal — capture device logs while we exercise the flow:
xcrun simctl spawn booted log stream --process Gitchat --predicate 'subsystem CONTAINS "AppUpdate" OR composedMessage CONTAINS "AppUpdate"'
```

In the iOS app, edit `GitchatIOS/Core/Config.swift` line 71:
```swift
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
```
Temporarily change the fallback `"1.0.0"` to `"0.1.0"` AND comment out the bundle lookup so the override sticks:
```swift
        // TEMP for smoke test
        return "0.1.0"
```

Rebuild + reinstall:
```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Gitchat.app
xcrun simctl launch booted chat.git
```

Expected: within ~1 second after launch, the soft banner slides down with `"New version 1.0.4 available"` and `"Minor bugs fixed"` (or whatever BE has at the time).

- [ ] **Step 11.3: Verify "Update now" presents the store sheet**

Tap **Update**. Expected log line (simulator path):
```
[AppStoreSheet] simulator: SKStoreProductViewController is a no-op; would open https://apps.apple.com/us/app/gitchat/id6762181976?uo=4
```
On a real device this would render the App Store sheet inline; on simulator the sheet is empty and dismissible — that is the expected, documented behavior.

- [ ] **Step 11.4: Verify dismiss → snooze**

Re-run the app fresh (kill + relaunch). Banner reappears. Tap **X**. Banner disappears immediately. Force-foreground (background + foreground): banner stays hidden.

In a Swift LLDB or by reading `UserDefaults`:
```bash
xcrun simctl spawn booted defaults read chat.git appUpdate.snoozedUntil
xcrun simctl spawn booted defaults read chat.git appUpdate.snoozedVersion
```
Expected: `snoozedVersion == "1.0.4"` (or whatever the live BE returns), `snoozedUntil` is a date ~24h ahead.

- [ ] **Step 11.5: Revert the smoke-test override**

Restore `GitchatIOS/Core/Config.swift` line 71 to its original form:
```swift
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
```
Confirm `git diff GitchatIOS/Core/Config.swift` is empty.

- [ ] **Step 11.6: Final full test run**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests
```
Expected: all pass.

- [ ] **Step 11.7: Push branch (ASK BEFORE PUSHING)**

Per project memory: **always ask explicit user approval before pushing.** Do not push without a fresh "yes" in this session. Once approved:

```bash
git push -u origin feat/in-app-update-gate-mvp
gh pr create --title "feat(ios): in-app update gate — MVP soft-prompt path (#66)" \
  --body "Implements PR #1 of in-app update gate per docs/superpowers/specs/2026-05-05-in-app-update-gate-mvp-design.md. Closes part of #43, syncs #66. Force-update + 426 + TestFlight deferred to PR #2."
```

---

## Coverage check vs. spec

- BE contract verified live → Task 1 (decoding test uses captured live JSON).
- `AppVersionManifest` model → Task 1.
- `SemVer` → Task 2.
- `APIClient.fetchAppVersionManifest()` + `VersionFetcher` protocol → Task 3.
- 3-state machine → Task 4.
- 1×/hr throttle + force bypass → Task 5.
- 24h snooze + version-key invalidation + immediate state flip → Task 6.
- `SKStoreProductViewController` wrapper + simulator guard + fallback URL → Task 7.
- Soft prompt UI → Task 8.
- `app_update` push case → Task 9.
- `RootView` wiring (overlay, sheet, `.task`, `scenePhase`) → Task 10.
- Smoke test (banner shows, update presents sheet, dismiss snoozes) → Task 11.
- Out of scope (force update, 426, TestFlight, `minimumSupportedVersion`) → confirmed deferred in spec; not implemented here.

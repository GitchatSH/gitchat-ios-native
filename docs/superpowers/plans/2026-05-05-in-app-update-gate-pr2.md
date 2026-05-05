# In-App Update Gate — PR #2 Implementation Plan (iOS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the iOS-side force-update path: `forceUpdateRequired` state, full-screen `ForceUpdateView`, HTTP 426 interceptor, TestFlight detection, debug bypass.

**Architecture:** Extend the PR #1 `AppUpdateChecker` state machine with a fourth case `.forceUpdateRequired(VersionInfo)`. Three triggers flip into it: `manifest.isForceUpdate=true`, `current < minimumSupportedVersion`, or HTTP 426 from any non-`/app/version` API call. `RootView` wraps its existing body in a conditional that swaps to `ForceUpdateView` when force state is active, tearing down all sheets/modals via SwiftUI re-rendering.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen, StoreKit (`SKStoreProductViewController`).

**Spec:** `docs/superpowers/specs/2026-05-05-in-app-update-gate-pr2-design.md`

**Branch:** `feat/in-app-update-gate-pr2` from `main`

**Note on commits:** This repo's convention is operator-driven commits — do not run `git commit` between tasks. After each task, the user reviews and commits manually if satisfied.

---

## File map

### New files

| File | Responsibility |
|---|---|
| `GitchatIOS/Core/AppUpdate/ForceUpdateView.swift` | Full-screen wall view, TestFlight detection, Update CTA |
| `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift` | Force-state machine unit tests (9 cases) |
| `GitchatIOSTests/Networking/APIClient426InterceptorTests.swift` | 426 interceptor tests (4 cases) |

### Modified files

| File | Change |
|---|---|
| `GitchatIOS/Core/Config.swift` | Add `appStoreFallback` constants (verify `userAgent` already correct) |
| `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` | Add `.forceUpdateRequired` case, force triggers in `apply(manifest:)`, `handle426()`, DEBUG bypass, `VersionInfo.fallback()` |
| `GitchatIOS/Core/Networking/APIClient.swift` | Add `intercept426IfNeeded` helper, wire into `request<T>` and `performUpload` |
| `GitchatIOS/App/RootView.swift` | Wrap existing body in conditional replace pattern |

---

## Task 1: Verify `Config.userAgent` and add `appStoreFallback`

**Files:**
- Modify: `GitchatIOS/Core/Config.swift`

- [ ] **Step 1: Verify `Config.userAgent` matches BE regex**

Read `GitchatIOS/Core/Config.swift` and confirm line 73 reads:
```swift
static let userAgent = "gitchat-ios/\(appVersion)"
```
The BE regex `^gitchat-(ios|android|macos)\/(\d+\.\d+\.\d+(?:[-+][\w.]+)?)/i` matches this. **No change needed if format matches.** If it doesn't, fix to the exact string above.

- [ ] **Step 2: Add `appStoreFallback` to Config**

Append after the `userAgent` line in `Config.swift`:

```swift
/// Hardcoded App Store identity for the in-app update gate. Used as a
/// fallback in `ForceUpdateView` when an HTTP 426 fires before any
/// `/app/version` manifest fetch has succeeded — the wall still needs a
/// working Update button.
static let appStoreFallback: (appStoreId: String, storeUrl: URL) = (
    appStoreId: "6762181976",
    storeUrl: URL(string: "https://apps.apple.com/us/app/gitchat/id6762181976")!
)
```

- [ ] **Step 3: Build to verify no compile errors**

```bash
cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

---

## Task 2: Extend `UpdateState` with `.forceUpdateRequired` case + force triggers

**Files:**
- Modify: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`
- Test: `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift` (new)

- [ ] **Step 1: Create the test file with 5 force-trigger tests**

Create `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerForceUpdateTests: XCTestCase {

    private struct StubFetcher: VersionFetcher {
        var manifest: AppVersionManifest
        func fetch() async throws -> AppVersionManifest { manifest }
    }

    private func makeManifest(
        latest: String = "1.5.0",
        minSupported: String = "1.0.0",
        force: Bool = false
    ) -> AppVersionManifest {
        AppVersionManifest(
            latestVersion: latest,
            releaseNotes: "Notes",
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: minSupported,
            isForceUpdate: force
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerForceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeChecker(
        manifest: AppVersionManifest,
        currentVersion: String
    ) -> AppUpdateChecker {
        AppUpdateChecker(
            fetcher: StubFetcher(manifest: manifest),
            defaults: makeDefaults(),
            currentVersion: { currentVersion },
            now: { Date() }
        )
    }

    // MARK: - Force triggers

    func test_isForceUpdateFlag_flipsToForceUpdateRequired() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.5.0", minSupported: "1.0.0", force: true),
            currentVersion: "1.5.0"   // up-to-date but force flag is set
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }

    func test_belowMinimum_flipsToForceUpdateRequired() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.5.0", minSupported: "1.2.0"),
            currentVersion: "1.1.0"
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }

    func test_equalToMinimum_notForced() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.2.0", minSupported: "1.2.0"),
            currentVersion: "1.2.0"
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_forceTakesPrecedenceOverSnooze() async {
        let defaults = makeDefaults()
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(manifest: makeManifest(latest: "2.0.0", minSupported: "2.0.0")),
            defaults: defaults,
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
        // Pre-snooze the user against 2.0.0
        defaults.set(Date().addingTimeInterval(60 * 60 * 24), forKey: "appUpdate.snoozedUntil")
        defaults.set("2.0.0", forKey: "appUpdate.snoozedVersion")
        await checker.check()
        // Force trigger (current < min) overrides snooze
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("force must override snooze, got \(checker.state)")
        }
    }

    func test_forceTakesPrecedenceOverUpdateAvailable() async {
        // latest > current AND force flag — must land on .forceUpdateRequired, not .updateAvailable
        let checker = makeChecker(
            manifest: makeManifest(latest: "2.0.0", minSupported: "1.0.0", force: true),
            currentVersion: "1.5.0"
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }
}
```

- [ ] **Step 2: Add the test file to xcodegen project**

```bash
cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native
xcodegen generate
grep -c "AppUpdateCheckerForceUpdateTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Expected: count > 0.

- [ ] **Step 3: Run the new tests — they MUST fail to compile**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerForceUpdateTests 2>&1 | tail -30
```
Expected: compile error referencing `forceUpdateRequired` (case doesn't exist yet).

- [ ] **Step 4: Add `.forceUpdateRequired` case to `UpdateState`**

In `AppUpdateChecker.swift`, replace the `UpdateState` enum (currently lines 16-20) with:

```swift
enum UpdateState: Equatable {
    case unknown
    case upToDate
    case updateAvailable(VersionInfo)
    case forceUpdateRequired(VersionInfo)
}
```

- [ ] **Step 5: Add force-trigger logic to `apply(manifest:)`**

In `AppUpdateChecker.swift`, replace the body of `apply(manifest:)` (currently lines 81-108) with:

```swift
private func apply(manifest: AppVersionManifest) {
    guard
        let latest = SemVer(manifest.latestVersion),
        let current = SemVer(currentVersion()),
        let minSupported = SemVer(manifest.minimumSupportedVersion)
    else {
        state = .unknown
        return
    }

    let info = VersionInfo(
        latest: latest,
        latestRaw: manifest.latestVersion,
        releaseNotes: manifest.releaseNotes,
        storeUrl: manifest.storeUrl,
        appStoreId: manifest.appStoreId
    )

    // Force triggers — bypass snooze entirely. Either the BE flipped
    // `isForceUpdate=true` (emergency override) or the user is below
    // the floor `minimumSupportedVersion`.
    if manifest.isForceUpdate || current < minSupported {
        #if DEBUG
        if Self.debugBypassEnabled {
            NSLog("[AppUpdateChecker] DEBUG bypass — would have forced update")
        } else {
            state = .forceUpdateRequired(info)
            return
        }
        #else
        state = .forceUpdateRequired(info)
        return
        #endif
    }

    // Soft path (PR #1 logic — unchanged)
    if !(current < latest) {
        state = .upToDate
        return
    }
    if let until = defaults.object(forKey: Self.kSnoozedUntil) as? Date,
       let snoozedVer = defaults.string(forKey: Self.kSnoozedVersion),
       until > now(),
       snoozedVer == manifest.latestVersion {
        state = .upToDate
        return
    }
    state = .updateAvailable(info)
}
```

- [ ] **Step 6: Add the DEBUG bypass static**

In `AppUpdateChecker.swift`, just inside the class body (after the `snoozeInterval` constant, before `init`), add:

```swift
#if DEBUG
private static var debugBypassEnabled: Bool {
    ProcessInfo.processInfo.environment["BYPASS_FORCE_UPDATE"] == "1"
}
#endif
```

- [ ] **Step 7: Run the 5 force-trigger tests**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerForceUpdateTests 2>&1 | tail -30
```
Expected: all 5 tests pass.

---

## Task 3: Add `VersionInfo.fallback()` and re-check exit condition test

**Files:**
- Modify: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`
- Modify: `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift`

- [ ] **Step 1: Add 1 more test for re-check exit condition**

Append to `AppUpdateCheckerForceUpdateTests.swift` inside the class:

```swift
func test_recheckUnflipsForceState() async {
    // Start with force state, then flip flag back via a second fetch
    final class MutableFetcher: VersionFetcher {
        var manifest: AppVersionManifest
        init(_ m: AppVersionManifest) { self.manifest = m }
        func fetch() async throws -> AppVersionManifest { manifest }
    }
    let initialForce = AppVersionManifest(
        latestVersion: "1.5.0", releaseNotes: nil, releasedAt: nil,
        storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
        appStoreId: "1", minimumSupportedVersion: "1.0.0", isForceUpdate: true
    )
    let mutable = MutableFetcher(initialForce)
    let checker = AppUpdateChecker(
        fetcher: mutable,
        defaults: makeDefaults(),
        currentVersion: { "1.5.0" },
        now: { Date() }
    )
    await checker.check()
    guard case .forceUpdateRequired = checker.state else {
        return XCTFail("expected force after first check, got \(checker.state)")
    }

    // BE flips flag back
    mutable.manifest = AppVersionManifest(
        latestVersion: "1.5.0", releaseNotes: nil, releasedAt: nil,
        storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
        appStoreId: "1", minimumSupportedVersion: "1.0.0", isForceUpdate: false
    )
    await checker.check(force: true)   // bypass throttle so the second check actually runs
    XCTAssertEqual(checker.state, .upToDate)
}
```

- [ ] **Step 2: Run the test — should pass without changes**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerForceUpdateTests/test_recheckUnflipsForceState 2>&1 | tail -10
```
Expected: pass. The existing `apply(manifest:)` already handles this — when force flag is false, the soft-path logic runs and returns `.upToDate`.

- [ ] **Step 3: Add `VersionInfo.fallback()` static**

Append to the bottom of `AppUpdateChecker.swift` (outside the class):

```swift
extension AppUpdateChecker.VersionInfo {
    /// Placeholder used by `handle426()` when an HTTP 426 fires before
    /// any successful manifest fetch — provides a working Update button
    /// via `Config.appStoreFallback`. The wall does not display the
    /// `latestRaw` value, so its placeholder is harmless.
    static func fallback() -> Self {
        .init(
            latest: SemVer("0.0.0")!,
            latestRaw: "—",
            releaseNotes: nil,
            storeUrl: Config.appStoreFallback.storeUrl,
            appStoreId: Config.appStoreFallback.appStoreId
        )
    }
}
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

---

## Task 4: Add `handle426()` method

**Files:**
- Modify: `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift`
- Modify: `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift`

- [ ] **Step 1: Add 3 tests for `handle426()`**

Append to `AppUpdateCheckerForceUpdateTests.swift`:

```swift
// MARK: - handle426()

func test_handle426_noCachedInfo_usesFallback() async {
    let checker = makeChecker(
        manifest: makeManifest(),         // unused — handle426 doesn't await fetch
        currentVersion: "1.0.0"
    )
    XCTAssertEqual(checker.state, .unknown)
    await checker.handle426()
    guard case .forceUpdateRequired(let info) = checker.state else {
        return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
    }
    // Fallback identity from Config.appStoreFallback
    XCTAssertEqual(info.appStoreId, Config.appStoreFallback.appStoreId)
    XCTAssertEqual(info.storeUrl, Config.appStoreFallback.storeUrl)
}

func test_handle426_withCachedInfo_reusesVersionInfo() async {
    // First make state .updateAvailable so we have cached VersionInfo
    let checker = makeChecker(
        manifest: makeManifest(latest: "1.5.0", minSupported: "1.0.0"),
        currentVersion: "1.0.0"
    )
    await checker.check()
    guard case .updateAvailable(let cached) = checker.state else {
        return XCTFail("expected .updateAvailable precondition, got \(checker.state)")
    }
    await checker.handle426()
    guard case .forceUpdateRequired(let info) = checker.state else {
        return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
    }
    XCTAssertEqual(info.appStoreId, cached.appStoreId)
    XCTAssertEqual(info.latestRaw, cached.latestRaw)
}

func test_handle426_idempotent() async {
    let checker = makeChecker(
        manifest: makeManifest(force: true),
        currentVersion: "1.0.0"
    )
    await checker.check()
    guard case .forceUpdateRequired(let firstInfo) = checker.state else {
        return XCTFail("expected force precondition")
    }
    await checker.handle426()
    guard case .forceUpdateRequired(let secondInfo) = checker.state else {
        return XCTFail("expected still force after handle426")
    }
    // Idempotent — info should be unchanged (no re-render churn)
    XCTAssertEqual(firstInfo, secondInfo)
}
```

- [ ] **Step 2: Run the 3 tests — they MUST fail to compile**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerForceUpdateTests/test_handle426_noCachedInfo_usesFallback 2>&1 | tail -10
```
Expected: compile error — `handle426` undefined.

- [ ] **Step 3: Add `handle426()` method to `AppUpdateChecker`**

In `AppUpdateChecker.swift`, append inside the class (after `snooze()`, before `apply(manifest:)`):

```swift
/// Called by the APIClient 426 interceptor. Bare HTTP-status signal —
/// flip to `.forceUpdateRequired` immediately using whatever
/// `VersionInfo` is cached (or the `Config.appStoreFallback` if none),
/// then fire a manifest re-check in the background to populate real
/// version data for the next render. Idempotent: if state is already
/// `.forceUpdateRequired`, returns without doing work.
func handle426() async {
    if case .forceUpdateRequired = state { return }

    let cached: VersionInfo? = {
        switch state {
        case .updateAvailable(let info), .forceUpdateRequired(let info):
            return info
        default:
            return nil
        }
    }()

    state = .forceUpdateRequired(cached ?? .fallback())

    // Background refresh. Failure is fine — fallback persists, and the
    // next foreground `check()` retries.
    await check(force: true)
}
```

- [ ] **Step 4: Run the 3 handle426 tests**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/AppUpdateCheckerForceUpdateTests 2>&1 | tail -20
```
Expected: all 9 tests in the file pass.

---

## Task 5: Add 426 interceptor to `APIClient`

**Files:**
- Modify: `GitchatIOS/Core/Networking/APIClient.swift`
- Test: `GitchatIOSTests/Networking/APIClient426InterceptorTests.swift` (new)

- [ ] **Step 1: Create the test file with 4 cases**

Create `GitchatIOSTests/Networking/APIClient426InterceptorTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class APIClient426InterceptorTests: XCTestCase {

    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return APIClient(session: session)
    }

    private func makeChecker() -> AppUpdateChecker {
        // Use a fresh suite-backed checker so the global singleton's
        // state isn't polluted across tests. We swap the singleton
        // pointer for the duration of each test using the test-only
        // override below.
        AppUpdateChecker(
            fetcher: NoopFetcher(),
            defaults: UserDefaults(suiteName: "APIClient426Tests-\(UUID().uuidString)")!,
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
    }

    private struct NoopFetcher: VersionFetcher {
        func fetch() async throws -> AppVersionManifest {
            throw NSError(domain: "noop", code: 1)
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        AppUpdateChecker._testOverride = makeChecker()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        AppUpdateChecker._testOverride = nil
        super.tearDown()
    }

    func test_426Response_triggersHandle426() async throws {
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()   // any non-/app/version GET

        // handle426 dispatches a Task — wait briefly for it to land
        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .forceUpdateRequired = AppUpdateChecker.shared.state else {
            return XCTFail("expected .forceUpdateRequired after 426; got \(AppUpdateChecker.shared.state)")
        }
    }

    func test_200Response_doesNotTriggerHandle426() async throws {
        StubURLProtocol.responseStatus = 200
        StubURLProtocol.responseBody = Data(#"{"data":{"users":[]}}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()

        try await Task.sleep(nanoseconds: 200_000_000)
        if case .forceUpdateRequired = AppUpdateChecker.shared.state {
            XCTFail("must not flip to force on 200")
        }
    }

    func test_appVersionEndpoint_skipsInterceptor() async throws {
        // Fire the 426 from the app/version endpoint itself — interceptor
        // must skip to avoid an infinite re-check loop.
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.fetchAppVersionManifest()

        try await Task.sleep(nanoseconds: 200_000_000)
        if case .forceUpdateRequired = AppUpdateChecker.shared.state {
            XCTFail("must not trigger handle426 from /app/version endpoint")
        }
    }

    func test_performUpload426_triggersHandle426() async throws {
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.uploadAttachment(
            data: Data([0x00]),
            filename: "x.bin",
            mimeType: "application/octet-stream",
            conversationId: "c1"
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .forceUpdateRequired = AppUpdateChecker.shared.state else {
            return XCTFail("expected force after upload 426; got \(AppUpdateChecker.shared.state)")
        }
    }
}
```

- [ ] **Step 2: Add the test file to project**

```bash
cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native
xcodegen generate
grep -c "APIClient426InterceptorTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Expected: count > 0.

- [ ] **Step 3: Add the `_testOverride` hook to `AppUpdateChecker`**

The tests need to swap the `shared` singleton. In `AppUpdateChecker.swift`, replace the `static let shared = ...` block with:

```swift
static var shared: AppUpdateChecker {
    _testOverride ?? _shared
}

private static let _shared = AppUpdateChecker(
    fetcher: APIClientVersionFetcher(),
    defaults: .standard,
    currentVersion: { Config.appVersion },
    now: { Date() }
)

#if DEBUG
nonisolated(unsafe) static var _testOverride: AppUpdateChecker?
#else
static var _testOverride: AppUpdateChecker? { nil }
#endif
```

- [ ] **Step 4: Run the 4 interceptor tests — they MUST fail (interceptor not wired)**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/APIClient426InterceptorTests 2>&1 | tail -30
```
Expected: 3 of 4 fail (`test_200Response_doesNotTriggerHandle426` may pass trivially; the 426 cases will fail because nothing yet calls `handle426()`).

- [ ] **Step 5: Add `intercept426IfNeeded` helper to `APIClient`**

In `APIClient.swift`, append a new method inside the `struct APIClient` (just before the closing `}` of the struct):

```swift
/// Fires `AppUpdateChecker.handle426()` when the response status is 426.
/// Skipped for the `/app/version` endpoint to avoid a re-check loop.
private func intercept426IfNeeded(_ http: HTTPURLResponse, request: URLRequest) {
    guard http.statusCode == 426 else { return }
    if request.url?.path.hasSuffix("/app/version") == true { return }
    Task { @MainActor in
        await AppUpdateChecker.shared.handle426()
    }
}
```

- [ ] **Step 6: Wire interceptor into `request<T>()`**

In `APIClient.swift`, find line 98 (`guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }`) and add the interceptor call **immediately after**:

```swift
guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
intercept426IfNeeded(http, request: req)
guard (200..<300).contains(http.statusCode) else {
    let text = String(data: data, encoding: .utf8)
    throw APIError.http(http.statusCode, text)
}
```

- [ ] **Step 7: Wire interceptor into `performUpload()`**

In `APIClient.swift`, replace the body of `performUpload()` (currently lines 309-316) with:

```swift
private func performUpload(_ req: URLRequest) async throws -> (Data, URLResponse) {
    let result: (Data, URLResponse)
    do {
        result = try await uploadSession.data(for: req)
    } catch let error as URLError where Self.isRetriableUploadError(error) {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        result = try await uploadSession.data(for: req)
    }
    if let http = result.1 as? HTTPURLResponse {
        intercept426IfNeeded(http, request: req)
    }
    return result
}
```

- [ ] **Step 8: Run all 4 interceptor tests**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/APIClient426InterceptorTests 2>&1 | tail -20
```
Expected: all 4 pass.

---

## Task 6: Build `ForceUpdateView`

**Files:**
- Create: `GitchatIOS/Core/AppUpdate/ForceUpdateView.swift`

- [ ] **Step 1: Create `ForceUpdateView.swift`**

Create `GitchatIOS/Core/AppUpdate/ForceUpdateView.swift`:

```swift
import SwiftUI
import UIKit

/// Full-screen blocker shown when `AppUpdateChecker.state ==
/// .forceUpdateRequired`. Mounted at `RootView` level via a conditional
/// replace, so SwiftUI tears down all sheets/modals/keyboards by
/// re-rendering the root tree.
///
/// No dismiss gesture, no sign-out, no escape. Single CTA opens the
/// App Store (or TestFlight when this build is sandbox-receipted).
struct ForceUpdateView: View {
    let info: AppUpdateChecker.VersionInfo
    @State private var showStoreSheet = false

    private var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            iconView
            Text("Update Required")
                .font(.title2.bold())
            Text("This version of Gitchat is no longer supported. Please update to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Update") { handleUpdateTap() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: $showStoreSheet) {
            AppStoreSheet(
                appStoreId: info.appStoreId,
                fallbackURL: info.storeUrl,
                onDismiss: { showStoreSheet = false }
            )
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let _ = UIImage(named: "AppIcon-Display") {
            Image("AppIcon-Display")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)
        }
    }

    private func handleUpdateTap() {
        if isTestFlight, let url = URL(string: "itms-beta://") {
            UIApplication.shared.open(url)
        } else {
            #if targetEnvironment(simulator)
            UIApplication.shared.open(info.storeUrl)
            #else
            showStoreSheet = true
            #endif
        }
    }
}
```

- [ ] **Step 2: Add the file to project**

```bash
cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native
xcodegen generate
grep -c "ForceUpdateView.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Expected: count > 0.

- [ ] **Step 3: Build to verify no compile errors**

```bash
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

---

## Task 7: Wire `ForceUpdateView` into `RootView`

**Files:**
- Modify: `GitchatIOS/App/RootView.swift`

- [ ] **Step 1: Wrap the existing body with the conditional replace pattern**

In `RootView.swift`, replace the `var body: some View { ... }` block (currently lines 21-109) with:

```swift
var body: some View {
    if case .forceUpdateRequired(let info) = updater.state {
        ForceUpdateView(info: info)
    } else {
        existingBody
    }
}

@ViewBuilder
private var existingBody: some View {
    Group {
        if auth.isAuthenticated {
            authedShell
                .task {
                    socket.connect()
                    if let login = auth.login { socket.subscribeUser(login: login) }
                    wireGlobalMessageBanner()
                    startHeartbeat()
                }
        } else {
            SignInView()
        }
    }
    .sheet(item: Binding(
        get: { router.pendingProfileLogin.map(ProfileLoginRoute.init(login:)) },
        set: { router.pendingProfileLogin = $0?.login }
    )) { route in
        NavigationStack { ProfileView(login: route.login) }
    }
    .sheet(item: Binding(
        get: { router.pendingInviteCode.map(InviteCodeRoute.init(code:)) },
        set: { router.pendingInviteCode = $0?.code }
    )) { route in
        InvitePreviewSheet(code: route.code)
    }
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
        }
    }
    .animation(.easeInOut(duration: 0.25), value: updater.state)
    .sheet(isPresented: $showUpdateStoreSheet) {
        if let info = pendingUpdateInfo {
            AppStoreSheet(
                appStoreId: info.appStoreId,
                fallbackURL: info.storeUrl,
                onDismiss: { showUpdateStoreSheet = false }
            )
        }
    }
    .task { await updater.check(force: true) }
    .onReceive(NotificationCenter.default.publisher(for: .gitchatWaveResponded)) { note in
        guard let cid = note.object as? String, !cid.isEmpty else { return }
        ToastCenter.shared.show(.success, "Waved back — opening chat")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AppRouter.shared.openConversation(id: cid)
        }
    }
    .onChange(of: scenePhase) { phase in
        if phase == .active, auth.isAuthenticated {
            PresenceStore.shared.heartbeatNow()
            Task { await PushSubscriptionSync.shared.syncCurrent() }
        }
        if phase == .active {
            Task { await updater.check() }
        }
    }
    .onChange(of: auth.isAuthenticated) { isAuth in
        if isAuth {
            socket.connect()
            if let login = auth.login { socket.subscribeUser(login: login) }
            startHeartbeat()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                requestReview()
            }
        } else {
            socket.disconnect()
            heartbeatTask?.cancel()
        }
    }
}
```

The wrap is the only change — `existingBody` is a verbatim move of the previous body content.

- [ ] **Step 2: Build to verify no compile errors**

```bash
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

---

## Task 8: Final verification — full test suite + manifest grep

**Files:** none (verification only)

- [ ] **Step 1: Regenerate project + verify all new files are wired**

```bash
cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native
xcodegen generate
for f in ForceUpdateView.swift AppUpdateCheckerForceUpdateTests.swift APIClient426InterceptorTests.swift; do
  count=$(grep -c "$f" GitchatIOS.xcodeproj/project.pbxproj)
  echo "$f: $count"
done
```
Expected: each file > 0 (typically 2 lines per file in pbxproj).

- [ ] **Step 2: Run the entire iOS test target**

```bash
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -30
```
Expected: `Test Suite 'All tests' passed`. PR #1 tests in `AppUpdateCheckerStateTests`, `AppUpdateCheckerThrottleTests`, `AppUpdateCheckerSnoozeTests` must still pass alongside the new ones.

- [ ] **Step 3: Manual sanity (skip if BE PR not yet local)**

If the BE PR is checked out locally:

```bash
# Backend running on http://localhost:3000 with seeded ios policy row
curl -u admin:secret -X PATCH http://localhost:3000/api/v1/admin/app/version \
  -H 'Content-Type: application/json' \
  -d '{"platform":"ios","isForceUpdate":true,"forceUpdateReason":"manual test"}'
```

Launch the iOS app pointing at `http://localhost:3000/api/v1` (use the `GitchatIOS local` scheme). Background then foreground the app — `ForceUpdateView` should appear within ≤1 `check()` cycle. Tap **Update** → `SKStoreProductViewController` sheet opens.

Flip back:
```bash
curl -u admin:secret -X PATCH http://localhost:3000/api/v1/admin/app/version \
  -H 'Content-Type: application/json' \
  -d '{"platform":"ios","isForceUpdate":false}'
```
Background then foreground — wall disappears, normal UI returns.

- [ ] **Step 4: Manual debug-bypass sanity**

```bash
# Build with BYPASS_FORCE_UPDATE=1 set in Xcode scheme env, OR launch via:
xcrun simctl launch --console-pty booted chat.git --BYPASS_FORCE_UPDATE 1
```
With BE policy still on `isForceUpdate=true`, the app launches normally — bypass log line `[AppUpdateChecker] DEBUG bypass — would have forced update` appears in the console.

---

## Self-review checklist

- [x] Task 1 covers `Config.userAgent` + `appStoreFallback` (spec § Component designs)
- [x] Task 2 covers force triggers + DEBUG bypass + 5 of 9 unit tests (spec § State machine)
- [x] Task 3 covers `VersionInfo.fallback()` + re-check exit (spec § Exit conditions)
- [x] Task 4 covers `handle426()` + 3 of 9 unit tests (spec § handle426)
- [x] Task 5 covers 426 interceptor + 4 of 4 unit tests (spec § APIClient 426 interceptor)
- [x] Task 6 covers `ForceUpdateView` + TestFlight detection (spec § ForceUpdateView)
- [x] Task 7 covers RootView replace pattern (spec § RootView)
- [x] Task 8 covers `xcodegen` + full test suite + manual sanity (spec § Verification)
- [x] All 9 force-update tests + 4 interceptor tests covered (spec § Test plan)

No placeholders. No "TBD", "TODO", or "appropriate error handling" steps. Every code block is complete.

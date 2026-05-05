# In-App Update Gate — MVP (PR #1)

**Status:** spec approved, ready for plan
**Date:** 2026-05-05
**Issues:** [#43](https://github.com/GitchatSH/gitchat-ios-native/issues/43) (parent spec), [#66](https://github.com/GitchatSH/gitchat-ios-native/issues/66) (sync from webapp PR #63)
**Scope:** PR #1 of 2 — soft-prompt path only. Force-update + 426 + TestFlight deferred to PR #2.

## Problem

Today the iOS app has no way to learn that a newer version exists. Users keep running old clients until they happen to check the App Store, which delays bug-fix rollout and leaves stale clients hitting the backend. The backend now exposes `GET /api/v1/app/version?platform=ios` (webapp PR #63) — iOS is the only remaining piece.

## Goal

Detect newer versions on launch and on foreground, show a soft banner, and let the user tap into an in-app App Store sheet (`SKStoreProductViewController`) without leaving the app.

## Non-goals (deferred to PR #2)

- `forceUpdateRequired` state and full-screen blocking cover
- HTTP 426 interceptor in `APIClient` request pipeline
- `minimumSupportedVersion` comparison
- TestFlight (`itms-beta://`) routing — store sheet only for now

## Backend contract (verified live)

`GET https://api-dev.gitchat.sh/api/v1/app/version?platform=ios` returned 200 with:

```json
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
```

Notes vs. parent spec:
- Response is wrapped in the standard NestJS `{ data, statusCode, message }` envelope. Existing `APIClient.request<T>()` already unwraps `APIEnvelope<T>` (see `APIClient.swift:108`), so the typed method is a one-liner.
- **No `latestBuild` field.** Parent spec mentioned it for tiebreaks; build-number tiebreak is dropped. Equal SemVer means equal version.
- No auth required on this endpoint (curl with no Bearer returns 200).

## File layout

New folder `GitchatIOS/Core/AppUpdate/`:

| File | Purpose |
|------|---------|
| `AppVersionManifest.swift` | `Decodable` struct matching the response inner-`data` shape. |
| `SemVer.swift` | Parse `"1.4.2"`; component-wise compare. Used for `latestVersion` vs. `Config.appVersion`. |
| `AppUpdateChecker.swift` | `@MainActor` `ObservableObject`. State machine, throttle, snooze, fetch. |
| `AppStoreSheet.swift` | `UIViewControllerRepresentable` wrapper around `SKStoreProductViewController`. |
| `UpdateBanner.swift` | SwiftUI soft-prompt banner view. |

Modified:

| File | Change |
|------|--------|
| `Core/Networking/APIClient.swift` | Add `func fetchAppVersionManifest() async throws -> AppVersionManifest`. |
| `Core/PushManager.swift` | Add `case "app_update":` → `Task { await AppUpdateChecker.shared.check() }`. |
| `App/RootView.swift` | `@StateObject` updater, banner overlay, sheet binding, `.task { check() }`, `.onChange(of: scenePhase)` trigger. |

Reference (read-only): `SemVer.swift` and `AppStoreSheet.swift` from `origin/feat/in-app-update-gate` (lngdao, 2026-04-24) — mechanical files that can inform but not be copied wholesale.

## Component designs

### `AppVersionManifest.swift`

```swift
struct AppVersionManifest: Decodable, Equatable {
    let latestVersion: String
    let releaseNotes: String?
    let releasedAt: Date?           // ISO8601 from BE — decoded via decoder.dateDecodingStrategy
    let storeUrl: URL
    let appStoreId: String
    let minimumSupportedVersion: String  // unused in MVP; parsed for PR #2
    let isForceUpdate: Bool              // unused in MVP; parsed for PR #2
}
```

The two `unused in MVP` fields are kept in the struct so PR #2 doesn't have to touch BE-contract code — it just starts using fields that are already there.

### `SemVer.swift`

```swift
struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ s: String)              // returns nil on parse failure
    static func < (lhs: Self, rhs: Self) -> Bool
}
```

Lenient: trims `v` prefix, ignores any `-prerelease` / `+build` suffix (split on `-` and `+`, keep the head). Two missing components default to 0 (`"1.0"` → `1.0.0`).

### `AppUpdateChecker.swift`

```swift
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()
    @Published private(set) var state: UpdateState = .unknown

    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)
    }

    struct VersionInfo: Equatable {
        let latest: SemVer
        let latestRaw: String       // for display
        let releaseNotes: String?
        let storeUrl: URL
        let appStoreId: String
    }

    func check(force: Bool = false) async   // entry point
    func snooze()                            // user tapped "Not now"
}
```

#### Throttle policy

- Cold launch (`.task` on `RootView`): always run, regardless of last-checked timestamp.
- Foreground resume (`scenePhase == .active`): skip if last-checked < 1 hour ago.
- Push tap (`type == "app_update"`): `check(force: true)` — bypass throttle.

Last-checked timestamp persisted in `UserDefaults` under `"appUpdate.lastCheckedAt"`.

#### Snooze policy

- `snooze()` writes `{ "snoozedVersion": <latestRaw>, "snoozedUntil": now + 24h }` to `UserDefaults` **and** transitions `state` to `.upToDate` immediately so the banner disappears without waiting for the next `check()`.
- On every `check()`, when `latest > current`, consult snooze before flipping to `.updateAvailable`:
  - If `snoozedUntil > now` AND `snoozedVersion == latestRaw` → state set to `.upToDate` (banner hidden).
  - If `snoozedVersion != latestRaw` (BE bumped) → snooze invalidated, banner shown.
  - If `snoozedUntil < now` → snooze expired, banner shown.

#### Error handling

Network failure / decode error: log via `NSLog`, leave `state` at its previous value (do **not** flip to `.unknown` — that would hide a banner the user already saw). Never throw to caller.

### `AppStoreSheet.swift`

`UIViewControllerRepresentable` wrapping `SKStoreProductViewController`. On `loadProduct` failure, fall back to `UIApplication.shared.open(storeUrl)`.

Simulator guard:
```swift
#if targetEnvironment(simulator)
    // log and dismiss
#else
    // present SKStoreProductViewController
#endif
```

### `UpdateBanner.swift`

Top-anchored slide-down banner. Content:
- Leading: small icon (SF Symbol `arrow.down.circle.fill`).
- Center: `"New version \(latestRaw) available"` + optional release notes (1 line, truncated).
- Trailing: "Update" button (primary) + `xmark` dismiss.

Uses existing `Core/UI/` color/typography tokens (matched at implementation time — pick the closest existing banner pattern).

### Push integration

`PushManager.swift` switch at line 75:
```swift
case "chat_message", "group_add", "reply", "pin_message":
    ...
case "mention":
    ...
case "follow":
    ...
case "wave":
    ...
case "app_update":                                       // NEW
    Task { await AppUpdateChecker.shared.check(force: true) }
```

Click handler routing only — no UI navigation needed. The banner appears whenever state flips, regardless of which screen the user is on.

### `RootView` wiring

```swift
@StateObject private var updater = AppUpdateChecker.shared
@State private var showStoreSheet = false
@State private var pendingInfo: AppUpdateChecker.VersionInfo?

var body: some View {
    MainTabView()
        .overlay(alignment: .top) {
            if case let .updateAvailable(info) = updater.state {
                UpdateBanner(
                    versionRaw: info.latestRaw,
                    notes: info.releaseNotes,
                    onUpdate: { pendingInfo = info; showStoreSheet = true },
                    onDismiss: { updater.snooze() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showStoreSheet) {
            if let info = pendingInfo {
                AppStoreSheet(appStoreId: info.appStoreId, fallbackURL: info.storeUrl)
            }
        }
        .task { await updater.check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await updater.check() } }
        }
}
```

## Test plan (XCTest, target `GitchatIOSTests`)

Per project memory: prefer automated testing over manual.

| Test file | Cases |
|-----------|-------|
| `SemVerTests.swift` | parse valid/invalid, `1.10.0 > 1.9.0`, equality, `v1.2.3` strip, `-prerelease` ignore, missing-components default. |
| `AppVersionManifestDecodingTests.swift` | Golden JSON fixture (the live response captured above) decodes via `APIEnvelope<AppVersionManifest>` — proves contract. |
| `AppUpdateCheckerStateTests.swift` | Inject a fake fetcher returning controlled manifests; assert: `latest > current` → `.updateAvailable`; `latest == current` → `.upToDate`; throttle skips second call within 1h; `force: true` bypasses throttle; snooze with same version hides banner; snooze with newer version surfaces banner. |

To make `AppUpdateChecker` testable: extract the network call into a `protocol VersionFetcher { func fetch() async throws -> AppVersionManifest }` with the production impl wrapping `APIClient.shared.fetchAppVersionManifest()`. The test substitutes a stub. `UserDefaults` is parameterized via init for snooze/throttle keys (default = `.standard`).

No UI tests in PR #1 — the banner is straightforward enough to verify by snapshot or manual inspection.

## Verification

After implementation:

```bash
xcodegen generate
grep -c "AppUpdateChecker.swift" GitchatIOS.xcodeproj/project.pbxproj    # must be > 0
grep -c "SemVer.swift" GitchatIOS.xcodeproj/project.pbxproj               # must be > 0
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15'
```

Manual sanity check on simulator: bump `Config.appVersion` lookup to return `"1.0.0"` (or stub the BE response to a higher `latestVersion`), confirm banner appears.

## Out of scope (PR #2)

- `forceUpdateRequired` state + `ForceUpdateView` full-screen cover
- HTTP 426 interceptor in `APIClient.request()`
- `minimumSupportedVersion` comparison + force-route
- TestFlight detection (`Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"`) + `itms-beta://` open

## Risks

- **Banner UX feels intrusive.** Mitigation: 24h snooze + foreground throttle. If still noisy in dogfood, raise the throttle to 6h.
- **App Store sheet doesn't render in Simulator.** Spec'd: simulator path logs + no-ops; banner still shows for visual QA.
- **`releasedAt` parse.** BE returns ISO8601 with `Z`. The shared decoder must use `.iso8601`. Check the global decoder config; if not set, decode `releasedAt` as `String` and parse separately to avoid breaking other endpoints.

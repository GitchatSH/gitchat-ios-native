# In-App Update Gate — PR #2 (Force-Update Path) — iOS

**Status:** spec draft
**Date:** 2026-05-05
**Repo:** `gitchat-ios-native`
**Branch:** `feat/in-app-update-gate-pr2` (from `main`)
**Issues:** [#43](https://github.com/GitchatSH/gitchat-ios-native/issues/43) (parent spec)
**Companion BE spec:** `gitchat-webapp/backend/docs/superpowers/specs/2026-05-05-update-gate-be-design.md`

## Problem

PR #1 ([#113](https://github.com/GitchatSH/gitchat-ios-native/pull/113), merged 2026-05-05) shipped the soft-prompt path: launch + foreground manifest fetch, snooze-able banner, in-app App Store sheet. The four pieces deferred to PR #2:

1. `forceUpdateRequired` state and full-screen blocking cover
2. HTTP 426 interceptor in `APIClient` request pipeline
3. `minimumSupportedVersion` comparison + force-route
4. TestFlight detection + `itms-beta://` open

PR #2 ships these four pieces in iOS. A companion BE PR ships the matching server-side enforcement (426 middleware, admin policy editor, push broadcaster cron). The two PRs can merge in either order — iOS degrades gracefully when BE is missing, and BE 426 has no effect when no iOS client is on a too-old version.

## Goal

When BE flips `isForceUpdate=true`, bumps `minimumSupportedVersion` past the user's version, or returns HTTP 426 on any API call, replace the entire iOS app surface with a full-screen "Update Required" cover. Single CTA opens the App Store (or TestFlight when running a TestFlight build). The cover blocks every screen including pre-auth, sheets, and the keyboard.

## Non-goals

- Release notes / version-number display on the cover (minimal copy by design)
- Sign-out / contact-support escape hatches
- Localization (the rest of the app is English-only Swift literals — match the convention)
- Distributed scale-out concerns (in-process flag mutex on BE side; not iOS's problem)
- Cron / push polling on BE — covered in companion BE spec

## Design decisions (recap from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Rollout sequencing | iOS + BE in parallel; either may merge first | Maximum decoupling. iOS PR #2 must be a no-op until BE flips a flag or returns 426. |
| ForceUpdateView UX | Minimal wall (icon + 1-line copy + 1 button) | YAGNI; users get version info on App Store anyway. |
| State precedence | force > soft-update > up-to-date | Force conditions bypass snooze. Any one of three triggers flips state. |
| Force trigger flip-back | Live (not sticky) — successful re-check can clear | Keeps semantics clean if BE flag is flipped back. |
| Mounting | Conditional replace at RootView (Q4-B) | Tears down all sheets/modals via SwiftUI. Wall covers pre-auth too. |
| Debug bypass | `#if DEBUG` + env `BYPASS_FORCE_UPDATE=1` | Engineers can build local versions below `minimumSupportedVersion` without being walled. |
| 426 body parsing | Skipped — bare status code is the signal | Minimal copy doesn't need version info from 426 body. Cached `VersionInfo` powers the Update button. |
| Cold-launch flicker | Accepted (~200–500 ms before `check()` completes) | A loading splash adds complexity for a barely-visible window. |

## State machine

`UpdateState` gains a fourth case:

```swift
enum UpdateState: Equatable {
    case unknown
    case upToDate
    case updateAvailable(VersionInfo)     // PR #1 — soft banner
    case forceUpdateRequired(VersionInfo) // PR #2 — full-screen cover
}
```

`VersionInfo` is unchanged from PR #1 (`latest`, `latestRaw`, `releaseNotes`, `storeUrl`, `appStoreId`).

### Trigger conditions (any → `.forceUpdateRequired`)

1. `manifest.isForceUpdate == true`
2. `SemVer(Config.appVersion) < SemVer(manifest.minimumSupportedVersion)`
3. Any HTTP 426 from `APIClient.request()` or `APIClient.performUpload()` (excluding `/app/version` itself)

### Exit conditions

- A successful manifest fetch returns flags that don't satisfy any of #1, #2 → state transitions to `.upToDate` (or `.updateAvailable` if `latest > current`).
- 426 alone does not unflip — only a manifest re-check does.
- `handle426()` is idempotent: if state is already `.forceUpdateRequired`, no-op.
- While in force state, re-checks fire on **next foreground** (`scenePhase == .active`). The cover does **not** auto-poll on a timer. If BE flips a force flag back to `false`, the user must background+foreground the app to recover. Acceptable because such flag-back events are rare.

### Snooze interaction

PR #1 snooze is bypassed when force conditions are true. The `apply(manifest:)` flow checks force conditions *before* consulting snooze.

### Debug bypass

```swift
#if DEBUG
private static var debugBypassEnabled: Bool {
    ProcessInfo.processInfo.environment["BYPASS_FORCE_UPDATE"] == "1"
}
#endif
```

When enabled, `apply(manifest:)` logs but does not flip to `.forceUpdateRequired`. `handle426()` is unaffected (intentional — engineers debugging 426 should still see the wall).

Set via Xcode scheme env or `SIMCTL_CHILD_BYPASS_FORCE_UPDATE=1` for CLI launches.

## File layout

### New

| File | Purpose |
|---|---|
| `GitchatIOS/Core/AppUpdate/ForceUpdateView.swift` | Full-screen `View` + TestFlight detection + Update CTA |
| `GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift` | State-machine unit tests (9 cases) |
| `GitchatIOSTests/Networking/APIClient426InterceptorTests.swift` | 426 interceptor tests (4 cases) |

### Modified

| File | Change |
|---|---|
| `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` | Add `.forceUpdateRequired` case, force-trigger logic in `apply(manifest:)`, `handle426()` method, debug bypass |
| `GitchatIOS/Core/Networking/APIClient.swift` | `intercept426IfNeeded` helper + 2 call sites (`request<T>`, `performUpload`) |
| `GitchatIOS/Core/Config.swift` | Verify `userAgent` format `gitchat-ios/<ver>`; add `appStoreFallback` constants |
| `GitchatIOS/App/RootView.swift` | Conditional replace pattern around existing body |

## Component designs

### `AppUpdateChecker` — `apply(manifest:)` revised

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

    // Force triggers (any) — bypass snooze entirely
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

    // ... existing soft-update logic from PR #1 (snooze + .updateAvailable / .upToDate)
}
```

### `AppUpdateChecker.handle426()` (new)

```swift
func handle426() async {
    if case .forceUpdateRequired = state { return }   // idempotent

    let cached: VersionInfo? = {
        if case .updateAvailable(let info) = state { return info }
        if case .forceUpdateRequired(let info) = state { return info }
        return nil
    }()

    state = .forceUpdateRequired(cached ?? .fallback())

    // Background refresh — populates real VersionInfo for next render.
    // Does not retry on failure; relies on next foreground check().
    await check(force: true)
}
```

### `VersionInfo.fallback()` (new static)

```swift
extension AppUpdateChecker.VersionInfo {
    static func fallback() -> Self {
        .init(
            latest: SemVer(0, 0, 0)!,
            latestRaw: "—",
            releaseNotes: nil,
            storeUrl: Config.appStoreFallback.storeUrl,
            appStoreId: Config.appStoreFallback.appStoreId
        )
    }
}
```

### `Config.appStoreFallback` (new)

```swift
static let appStoreFallback = (
    appStoreId: "6762181976",
    storeUrl: URL(string: "https://apps.apple.com/us/app/gitchat/id6762181976")!
)
```

These hardcoded values back the Update button when 426 fires before a manifest has ever been fetched.

### `Config.userAgent` (verify / fix)

Required format for BE 426 middleware to parse:

```swift
static let userAgent = "gitchat-ios/\(appVersion) (iOS \(UIDevice.current.systemVersion))"
```

If the existing `Config.userAgent` doesn't match `gitchat-(ios|android|macos)/<semver>`, fix it as task #1 of the iOS plan. Otherwise no change.

### `ForceUpdateView`

```swift
struct ForceUpdateView: View {
    let info: AppUpdateChecker.VersionInfo
    @State private var showStoreSheet = false

    private var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("AppIcon-Display")
                .resizable().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
            Text("Update Required").font(.title2.bold())
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
            AppStoreSheet(appStoreId: info.appStoreId, fallbackURL: info.storeUrl)
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

`AppIcon-Display` asset may not exist yet — verify at impl time and either add or fall back to `Image(systemName: "arrow.down.circle.fill")`.

### `APIClient` 426 interceptor

```swift
/// Fires AppUpdateChecker.handle426() when the response status is 426.
/// Skipped for the /app/version endpoint to prevent a re-check loop.
private func intercept426IfNeeded(_ http: HTTPURLResponse, request: URLRequest) {
    guard http.statusCode == 426 else { return }
    if request.url?.path.hasSuffix("/app/version") == true { return }
    Task { @MainActor in
        await AppUpdateChecker.shared.handle426()
    }
}
```

Wired in `request<T>()` immediately after the `HTTPURLResponse` cast (line 98), and at the end of `performUpload()` after the response is in hand. Both call sites do not short-circuit — non-2xx still throws `APIError.http(...)` as before.

### `RootView` replace pattern

```swift
var body: some View {
    Group {
        if case .forceUpdateRequired(let info) = updater.state {
            ForceUpdateView(info: info)
        } else {
            existingRootContent     // MainTabView / BeforeAuthRootView + banner overlay + sheet
        }
    }
    .task { await updater.check() }
    .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await updater.check() } }
    }
}
```

`.task` and `.onChange` stay outside the `Group` so re-checks fire even after state flips back to `.upToDate`.

## BE contract iOS depends on

(Full spec: `gitchat-webapp/backend/docs/superpowers/specs/2026-05-05-update-gate-be-design.md`.)

iOS assumes:

- `GET /api/v1/app/version?platform=ios` continues to return the same `AppVersionManifest` shape PR #1 already consumes.
- HTTP 426 may be returned on any **non-`/app/version`** API endpoint when the request's User-Agent indicates `gitchat-ios/<ver>` below `minimumSupportedVersion`.
- 426 response body is opaque to iOS — bare status code is the signal. iOS does not parse 426 body for manifest fields.
- OneSignal `app_update` push payload shape is unchanged from PR #1's expectation: `data.type == "app_update"` triggers the existing `PushManager` handler.
- BE 426 middleware skips its own `/app/version` endpoint (else iOS would re-fetch and re-426 forever).

iOS handles BE absence gracefully:

- 426 middleware not deployed → interceptor never fires; manifest-driven force still works.
- Push broadcaster not deployed → no `app_update` push; manifest-driven check on launch/foreground still works.
- Admin endpoint not deployed → operator must `psql` the policy row directly. iOS doesn't care.

## Test plan

`GitchatIOSTests/AppUpdateCheckerForceUpdateTests.swift` — 9 cases:

1. `manifest.isForceUpdate=true` → `.forceUpdateRequired` regardless of version
2. `current < minimumSupportedVersion` → `.forceUpdateRequired`
3. `current == minimumSupportedVersion` (boundary) → not forced
4. force takes precedence over snooze
5. force takes precedence over `.updateAvailable`
6. `handle426()` with no cached info → `.forceUpdateRequired` with fallback `VersionInfo`
7. `handle426()` with cached `.updateAvailable` info → reuses cached `VersionInfo`
8. `handle426()` is idempotent when already `.forceUpdateRequired`
9. successful re-check after BE flag flips back → state returns to `.upToDate`

`GitchatIOSTests/Networking/APIClient426InterceptorTests.swift` — 4 cases:

1. 426 response → `AppUpdateChecker.handle426()` invoked
2. 200 response → `handle426()` not invoked
3. `/app/version` 426 → `handle426()` not invoked (loop guard)
4. `performUpload` 426 → `handle426()` invoked

Test infra reuses PR #1's `StubURLProtocol` (see `APIClientTopicURLTests.swift`).

## Verification

```bash
cd gitchat-ios-native
xcodegen generate
grep -c "ForceUpdateView.swift" GitchatIOS.xcodeproj/project.pbxproj                       # > 0
grep -c "AppUpdateCheckerForceUpdateTests.swift" GitchatIOS.xcodeproj/project.pbxproj      # > 0
grep -c "APIClient426InterceptorTests.swift" GitchatIOS.xcodeproj/project.pbxproj          # > 0
xcodebuild -scheme GitchatIOS -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15'
```

Manual sanity (requires BE local + iOS sim pointing at it):

```bash
# Flip force flag via admin endpoint
curl -u admin:<basic-pass> \
  -X PATCH http://localhost:3000/api/v1/admin/app/version \
  -H 'Content-Type: application/json' \
  -d '{"platform":"ios","isForceUpdate":true,"forceUpdateReason":"test"}'

# Foreground iOS app → wall appears within ≤1 check() cycle
# Flip back: -d '{"platform":"ios","isForceUpdate":false}'
# Foreground iOS → wall disappears
```

## Build sequence

1. `Config.userAgent` format + `appStoreFallback` constants
2. `AppUpdateChecker.swift` — `.forceUpdateRequired` case + force-trigger logic + DEBUG bypass + `handle426()`
3. `ForceUpdateView.swift`
4. `APIClient.swift` — `intercept426IfNeeded` + 2 call sites
5. `RootView.swift` — replace pattern
6. Tests
7. `xcodegen generate` + `grep -c` verify + `xcodebuild test`
8. Manual sanity once BE PR is up

## Risks

- **`Config.userAgent` regression risk.** If a future change strips the `gitchat-ios/<ver>` prefix, BE middleware silently no-ops and 426 never fires. Plan task #1 verifies and fixes the format; consider a unit test asserting the regex match.
- **Cold-launch flicker.** ~200–500 ms of normal UI before `check()` completes. Accepted (Q3 / A1).
- **`handle426()` placeholder VersionInfo.** When 426 fires before any manifest fetch, the wall renders with `latestRaw = "—"`. Minimal copy doesn't display this, so user-visible impact is zero. Update button still works via `Config.appStoreFallback`.
- **Asset `AppIcon-Display`** may not exist. Verify at impl; fall back to SF Symbol.
- **Socket.IO connections bypass interceptor.** WS `connect_error` does not flip state. BE doesn't 426 on WS upgrade; acceptable.
- **No retry on `handle426()` background fetch.** If the fetch fails, fallback `VersionInfo` persists. Self-heals on next foreground.

# Guest Mode + Phase-out Sign in with Apple — Design

**Date:** 2026-05-07
**Issue:** [GitchatSH/gitchat-ios-native#117](https://github.com/GitchatSH/gitchat-ios-native/issues/117)
**Status:** Spec — pending approval

## Goal

Reframe Gitchat iOS as a "GitHub content client" that opens directly into a
browse experience, with sign-in deferred to the moment the user attempts an
interactive action. Then remove Sign in with Apple in a follow-up release.

This document defines a single design covering two release phases. Each phase
ships its own implementation plan + PR.

## Phases

| Phase | Scope | Trigger |
|---|---|---|
| 1 | Guest mode (browse-first launch + locked-action sign-in sheet) + App Store metadata update emphasizing GitHub-client positioning | Spec approved |
| 2 | Remove Sign in with Apple button | Phase 1 has soaked ≥2 weeks on TestFlight + production without App Store review issues |

Out of scope for both phases:
- Migration / force-link of existing Apple-only accounts to GitHub.
- Wiring up the existing dead `LinkGithubWall` (its OAuth call overwrites
  rather than links — needs separate spec with proper BE link semantics).
- New BE endpoints. All guest-mode reads use existing public endpoints.
- Any change to BE `/auth/apple-link` route.

## User-visible flow

### Cold launch — no token in keychain (new user, or reinstall)

1. App opens directly into `GuestTabView` (2 tabs: Discover, Search).
2. Persistent "Sign in" button in nav header.
3. Discover loads `GET /trending/repos` + `/trending/people`.
4. Search tab: text field → `GET /user/:username` → push `ProfileView`.

### Guest taps a locked action (wave, follow, DM, post, react)

1. `SignInPromptSheet(reason:)` slides up from bottom.
2. Sheet shows action-typed title (e.g. "Sign in to wave at @ethan") + 1
   GitHub button.
3. Cancel → sheet dismisses, user stays in `GuestTabView`.
4. Sign-in success → `AuthStore.isAuthenticated` flips → RootView re-renders
   into `MainTabView`. The original action is **not retried** in v1 (context
   loss accepted; AppRouter-based deep-link replay deferred to v1.1).

### Cold launch — token in keychain (existing user)

Unchanged from today: RootView routes straight to `MainTabView`. Apple-only
users continue to see 401-driven empty states on `/github/data/*` endpoints.
Issue #117 explicitly accepts this status quo.

### Sign out from `MainTabView`

After sign-out, RootView re-renders into `GuestTabView` (not `SignInView`).

## Architecture changes

### `RootView.swift`

Routing changes from binary to:

```
isAuthenticated  → MainTabView   (existing)
otherwise        → GuestTabView  (new)
```

`SignInView` is no longer reachable from RootView — it becomes a
`.fullScreenCover` presented from `GuestTabView`'s "Sign in" header button
and from `SignInPromptSheet`.

### New: `GuestTabView`

Lives next to `MainTabView` in `App/`. Two tabs:

- **Discover** — reuses `DiscoverView` (see DiscoverViewModel changes).
- **Search** — new minimal screen: `TextField` + submit → `ProfileView`.

Header: persistent "Sign in" button (toolbar trailing item) → opens
`SignInView` as `.fullScreenCover`.

### New: `SignInPromptSheet`

Single component, generic over reason:

```swift
enum SignInReason {
    case wave(login: String)
    case dm(login: String)
    case follow(login: String)
    case post
    case react
    case invite     // accept invite from InvitePreviewSheet

    var title: String { /* per-case copy */ }
}

struct SignInPromptSheet: View {
    let reason: SignInReason
    let onDismiss: () -> Void
    // body: title + 1 GitHub button (calls SignInViewModel.startGithub)
}
```

Each call site presents this sheet via `.sheet(isPresented:)`.

### Modified: `DiscoverViewModel`

`loadAll()` branches on `AuthStore.shared.isAuthenticated`:

- **Authed (existing):** `friendsMutual()`, `fetchStarredRepos()`,
  Communities sub-tab visible.
- **Guest (new):** `GET /trending/repos`, `/trending/people`. Communities
  sub-tab hidden (sub-tab list filtered when guest).

Both endpoints already exist in `TrendingController` (no `@UseGuards`,
verified 2026-05-07). The iOS client needs new methods on `APIClient`.

### Modified: `ProfileView`

`load()` already calls `userProfile(login:)` which hits `GET /user/:username`.
Backend confirmed unguarded. iOS `APIClient.userProfile(login:)` must pass
`requireAuth: false` (same caveat as `previewInvite` below — without it the
client throws `APIError.notAuthenticated` synchronously for guest callers
before the request leaves the device). With that one-line fix in place no
further changes are needed for the guest read flow. Locked actions (wave /
follow buttons) gain a guest branch:

```swift
if AuthStore.shared.isAuthenticated {
    // existing wave/follow path
} else {
    showSignInPromptSheet(reason: .wave(login: profile.login))
}
```

Additionally, `loadFollowStatus()` short-circuits for guests and synthesizes
a non-mutual `FollowStatus(following: false, followed_by: false)`, so the
view enters its non-mutual branch and renders the Wave CTA. Without this,
the unauthenticated `/users/:login/follow-status` call throws
`.notAuthenticated`, `followState` stays nil, and the view falls into the
mutual-following branch (Follow + Chat) — Wave never renders for guests.

### Phase 2: SIWA removal

Single-file change:

```swift
// SignInView.swift — remove this block:
SignInWithAppleButton(...)
    .signInWithAppleButtonStyle(...)
    .frame(...)
    .clipShape(Capsule())
```

Kept as dead code (revertible in 1 line if Apple rejects):
- `SignInViewModel.handleApple()`
- `APIClient.appleLink()`, `AppleLinkRequest`, `AppleLinkResponse`
- BE route `POST /auth/apple-link`

**Known regression to document in PR #2:** Apple-only users who sign out or
reinstall after the button is pulled have no recovery path. Token in
keychain still authenticates, so already-signed-in Apple-only users keep
working. Issue #117 accepts this implicit lockout.

## Error handling

| Scenario | Behavior |
|---|---|
| `/trending/*` fails (network/5xx) | Discover shows retry banner (matches existing `ProfileView` error pattern). |
| `/user/:username` 404 | Search shows "User not found" inline. |
| `/user/:username` 5xx | Search shows retry. |
| Deep link `gitchat://invite/...` while guest | Present existing `InvitePreviewSheet`. BE confirmed `GET conversations/join/:code` is public; iOS `APIClient.previewInvite()` must add `requireAuth: false` (currently defaults to `true` and would block before the request leaves the device). Sheet's "Accept" CTA gates behind sign-in via `SignInPromptSheet(reason: .invite)`. |
| Apple-only existing token in keychain | Status quo: empty `/github/data/*` responses, identity-mismatch errors. Not fixed in this spec. |
| Sign out from `MainTabView` | RootView falls through to `GuestTabView`. |

## Testing

XCUITest scenarios (new test target — repo currently has no XCTest):

1. **Cold launch fresh keychain** → `GuestTabView` visible, Discover renders
   trending content.
2. **Tap "Sign in" header** → `SignInView` cover appears, mock OAuth →
   `MainTabView` visible after dismiss.
3. **Tap wave on a profile while guest** → `SignInPromptSheet` appears with
   correct title, Cancel returns user to `ProfileView` in `GuestTabView`.
4. **Pre-populated keychain (existing user)** → `MainTabView` cold launch
   (regression check).
5. **Sign out from `MainTabView`** → land on `GuestTabView`, not
   `SignInView`.

Non-UI verification:
- `xcodebuild` clean build with the new files registered in
  `project.pbxproj` (per CLAUDE.md `xcodegen` workflow).
- Manual Apple-only token check via simctl with pre-loaded keychain →
  confirm RootView still routes to `MainTabView`.

## App Store metadata

Phase 1 PR includes a metadata update emphasizing the GitHub-client framing.
**Copy is TBD** — to be drafted with the actual PR. Targets:

- App Store description first paragraph
- Keywords (add "github", "browse", "developer client" type terms)
- Promotional text

## Implementation sequence

1. **Phase 1 PR** — `GuestTabView`, `SignInPromptSheet`, `DiscoverViewModel`
   guest branch, `RootView` 3-way routing, `ProfileView` locked actions,
   `APIClient` trending methods, App Store metadata.
2. **TestFlight beta** — soak ≥2 weeks. Watch for App Store review feedback
   on the guest-mode shape.
3. **Phase 2 PR** — pull the `SignInWithAppleButton` block from
   `SignInView`. ~10 line diff.

## Open questions

- App Store metadata copy (deferred to PR drafting).
- Whether we want the v1.1 deep-link replay (action retried after sign-in).
  Currently scoped out; revisit if user research shows the context loss
  hurts conversion.

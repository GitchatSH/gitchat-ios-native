# Guest Mode (Phase 2) — Sign in with Apple Removal Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull the `SignInWithAppleButton` from `SignInView` so new users can only sign in via GitHub. Existing Apple-only users continue to authenticate via cached keychain tokens; signed-out / re-installed Apple-only users have no recovery path (accepted regression — see spec).

**Architecture:** Single-file delete in `SignInView.swift`. `SignInViewModel.handleApple(...)`, `APIClient.appleLink(...)`, and the BE `/auth/apple-link` route stay as dead code so a 1-line revert can re-add the button if the App Store rejects the change.

**Spec:** `docs/superpowers/specs/2026-05-07-guest-mode-and-phase-out-siwa-design.md` (Phase 2 section).

**Phase 1 prerequisite:** This plan only ships AFTER Phase 1 has soaked ≥2 weeks on TestFlight + ≥1 week on production with no App Store review feedback flagging the guest-mode shape.

**Tech Stack:** SwiftUI, iOS 16+, XcodeGen, XCUITest.

---

## File Structure

**Modify:**
- `GitchatIOS/Features/Auth/SignInView.swift` — remove the `SignInWithAppleButton(...)` block.
- `docs/APP_STORE_SUBMISSION.md` — drop the legacy SIWA mention from Description and Notes for Review.

**Test:**
- `GitchatIOSUITests/GuestModeTests.swift` — add a regression test confirming `SignInWithAppleButton` is no longer reachable from `SignInView`.

**Untouched (kept as dead code):**
- `GitchatIOS/Features/Auth/SignInView.swift` — `SignInViewModel.handleApple(...)`.
- `GitchatIOS/Core/Networking/APIClient.swift` — `appleLink(...)`, `AppleLinkRequest`, `AppleLinkResponse`.
- Backend route `POST /auth/apple-link`.

---

## Pre-flight checklist (MUST be true before starting Task 1)

- [ ] Phase 1 has been on TestFlight for ≥2 weeks (build with guest mode + locked-action sheet shipped).
- [ ] Phase 1 has been on production for ≥1 week (released via App Store Connect).
- [ ] No App Store review feedback flagging the guest-mode UX or 4.8 exception positioning.
- [ ] Crash-free rate ≥99% on Phase 1 build (check via Firebase Crashlytics).
- [ ] Analytics confirm guest funnel events (`guest_signin_prompt_shown` / `tapped`) are firing — proves the metric instrumentation Phase 1 added is working before we lean on it for Phase 2.

If any item is false, **stop**. Phase 2 is gated on Phase 1 stability evidence.

---

### Task 1: Pull `SignInWithAppleButton` from `SignInView`

**Files:**
- Modify: `GitchatIOS/Features/Auth/SignInView.swift`

- [ ] **Step 1: Read the current `SignInView` body**

Open `GitchatIOS/Features/Auth/SignInView.swift`. Locate the `SignInWithAppleButton(...)` block — it sits inside the `VStack(spacing: 12)` after the GitHub button (around line 165 of the current file). The block looks roughly:

```swift
                    // Sign in with Apple
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { req in
                            req.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            vm.handleApple(result)
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .clipShape(Capsule())
```

Verify the exact lines before editing — `xcodegen` generation between Phase 1 and Phase 2 may shift line numbers slightly.

- [ ] **Step 2: Delete the block**

Remove the entire `SignInWithAppleButton(...)` ... `.clipShape(Capsule())` block (and its `// Sign in with Apple` comment if present). The surrounding `VStack(spacing: 12) { ... }` becomes a single-button container with just the GitHub button.

The `import AuthenticationServices` line at the top of the file stays — `vm.handleApple(...)` is still referenced from kept-as-dead `SignInViewModel`. (If lint flags the import as unused after the delete, then `vm.handleApple` was the only reachable consumer in this file — but `SignInViewModel.handleApple` is still defined and could be re-exposed by a 1-line revert. Keep the import.)

- [ ] **Step 3: Keep `vm.handleApple`, `APIClient.appleLink`, `AppleLinkRequest/Response` in place**

Do NOT remove these. They are intentional dead code — the revert path. Verify they still compile:

```bash
xcodebuild build -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: BUILD SUCCEEDED, no warnings about dead code (Swift doesn't warn for `internal` symbols that are unused at module level).

- [ ] **Step 4: Run the existing test suite**

```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests
```

Expected: same baseline as end of Phase 1.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Auth/SignInView.swift
git commit -m "feat(auth): remove Sign in with Apple button (Phase 2 — revertible)"
```

---

### Task 2: Update App Store metadata to drop SIWA mention

**Files:**
- Modify: `docs/APP_STORE_SUBMISSION.md`

- [ ] **Step 1: Drop the SIWA mention from the Description**

In the Description section, the current copy includes the line:

```
• Sign in with Apple also supported (legacy)
```

Remove that bullet entirely. The "BUILT FOR DEVELOPERS" section now reads:

```
BUILT FOR DEVELOPERS

• Sign in with GitHub — one tap, no passwords
• Profile shows your top repositories, stars, followers, and contributed projects
• Works alongside the Gitchat extension for VS Code and Cursor — your chats stay in sync whether you're on your phone or in your editor
```

- [ ] **Step 2: Update Notes for Review**

Remove the "Sign in with Apple flow (legacy)" subsection entirely. The Notes block keeps the "Authenticated flow" section (GitHub OAuth) and the Guideline 4.8 paragraph, but drops the SIWA-specific instructions.

Specifically, replace the Guideline 4.8 paragraph to remove the "Sign in with Apple is offered as an equivalent option" sentence (since it's no longer offered). The paragraph becomes:

```
Per Guideline 4.8, Gitchat qualifies for the "client for a specific third-party
service" exception — every interactive feature (DMs, waves, follows, repo
channels) maps to GitHub-identity-keyed content. Users who do not wish to
provide GitHub credentials can browse the app without signing in.
```

- [ ] **Step 3: Commit**

```bash
git add docs/APP_STORE_SUBMISSION.md
git commit -m "docs(appstore): drop SIWA mention from metadata (Phase 2)"
```

> The actual App Store Connect submission must be re-uploaded after this change. The Description field is NOT editable without resubmission. Promotional Text is editable separately and was already updated in Phase 1.

---

### Task 3: Add regression test — `SignInWithAppleButton` is gone

**Files:**
- Modify: `GitchatIOSUITests/GuestModeTests.swift`

- [ ] **Step 1: Add the test**

Append to `GuestModeTests`:

```swift
    func test_signin_view_no_longer_offers_apple_button() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()

        // Reach SignInView via the Discover toolbar Sign-in button.
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 5))
        let signInToolbar = app.navigationBars.buttons["Sign in"]
        XCTAssertTrue(signInToolbar.exists, "Discover Sign-in toolbar must be present for guests")
        signInToolbar.tap()

        // Sign in with GitHub button is the sole CTA.
        XCTAssertTrue(app.buttons["Sign in with GitHub"].waitForExistence(timeout: 3),
                      "GitHub sign-in button must be present after Phase 2")

        // Sign in with Apple button MUST be gone. SwiftUI's
        // SignInWithAppleButton renders an accessibility element with
        // the label "Sign in with Apple" (or a localised variant).
        XCTAssertFalse(app.buttons["Sign in with Apple"].exists,
                       "SignInWithAppleButton must NOT be reachable in Phase 2")

        // Be defensive: also check for the localised iOS-side variant
        // that SignInWithAppleButton sometimes registers.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Apple'")).firstMatch.exists,
                       "No button containing 'Apple' should exist on the sign-in screen")
    }
```

- [ ] **Step 2: Run**

```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSUITests/GuestModeTests/test_signin_view_no_longer_offers_apple_button
```

Expected: PASS (after Task 1 lands). Run BEFORE Task 1 if you want to verify the failing-first state — the test would fail because `Sign in with Apple` button still exists.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOSUITests/GuestModeTests.swift
git commit -m "test(uitest): regression — SignInView omits Apple button after Phase 2"
```

---

## Verification before opening PR

- `xcodebuild build` clean.
- `xcodebuild test ... -only-testing:GitchatIOSTests` baseline preserved.
- `xcodebuild test ... -only-testing:GitchatIOSUITests/GuestModeTests` — all tests pass (including the new Phase 2 regression test).
- Manual sim sanity: cold launch as guest → tap Sign in toolbar → SignInView shows ONE button (Sign in with GitHub). No Apple button.
- Existing Apple-only user with a token in keychain still launches into `MainTabView` (they're using the cached token, not the deleted button).
- App Store Connect Description re-submitted (drops the legacy SIWA bullet).

## Done definition

- 3 commits on a `feat/guest-mode-phase2` branch.
- Single ~10-line code change + 1 regression test + 2 small doc edits.
- App Store binary uploaded to TestFlight (and then Production after acceptable soak).

## Rollback plan

If App Store rejects the Phase 2 build flagging the SIWA removal:

1. Revert Task 1 (re-add the `SignInWithAppleButton` block from the dead-code references). The block is preserved in commit history — `git show <task1-sha>` shows the exact lines to restore.
2. Revert Task 2 (re-add the SIWA bullet to Description, Notes for Review).
3. Submit a new build to TestFlight + App Store. Existing users are unaffected (their cached tokens still work).

Total rollback time: ~30 minutes including binary upload.

---

## Open question

- **App Store screenshot regeneration.** The submission pack lists "Sign-in screen with the Gitchat logo and the two sign-in buttons" as suggested screenshot #1. After Phase 2, this screenshot should be regenerated to show only the GitHub button. Track this in the PR description as a deliverable for whoever manages App Store Connect.

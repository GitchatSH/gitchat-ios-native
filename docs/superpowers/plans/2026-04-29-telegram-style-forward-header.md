# Telegram-style forward header — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iOS forwarded-message bubbles render with the existing styled "Forwarded from @login" header at the top of the bubble, instead of leaking the literal `> Forwarded from @user` body prefix into the rendered text.

**Architecture:** Two iOS-only file edits. (1) Flexibilize the prefix regex in `ChatMessageText.swift` so it matches the BE's actual `> Forwarded from @user\n\n…` format. (2) Refactor `ChatMessageView.swift` to extract the inline forwarded-header HStack into a `@ViewBuilder` helper, then move its call site from below the attachment to the top of the bubble VStack. No backend, schema, DTO, or extension changes.

**Tech Stack:** SwiftUI, Swift 5.10, iOS 16+. XcodeGen-managed project. No XCTest target — verification is `xcodebuild` compile + manual simulator scenarios per `CLAUDE.md`.

**Spec:** [`docs/superpowers/specs/2026-04-29-telegram-style-forward-header.md`](../specs/2026-04-29-telegram-style-forward-header.md)

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift` | Modify lines 92-98 | Pure text-processing helpers. Update `forwardedRegex` to flexibly accept BE's blockquote-prefixed format. |
| `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift` | Modify around line 366 (add helper) and around lines 480-504 (reorder VStack) | Per-message bubble layout. Hoist the forwarded-from header to the top of the bubble; extract the existing inline HStack into a `@ViewBuilder` helper to keep the VStack scannable. |

No new files. No deletions. No `project.pbxproj` regeneration needed (no Swift files added/renamed).

---

## Task 1: Flexibilize `forwardedRegex` so it matches the BE's actual format

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift:92-98`

The current regex `^Forwarded from @<login>\n` never matches the backend's actual emit format `> Forwarded from @<login>\n\n…`, so `parseForwarded` always returns `(nil, raw)` and the styled header in `ChatMessageView` never fires. Updating just the regex (no signature, no caller change) makes both the legacy stored bodies and all future BE forwards parse correctly.

- [ ] **Step 1: Read the current regex block (sanity check before editing)**

```bash
sed -n '90,100p' GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift
```

Expected output (verbatim):

```
    // MARK: Privates

    private static let forwardedRegex: NSRegularExpression? = {
        // "Forwarded from @<login>\n" — capture login in group 1.
        try? NSRegularExpression(
            pattern: #"^Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n"#,
            options: []
        )
    }()
```

If the lines don't match, stop and re-read the file — line numbers may have drifted.

- [ ] **Step 2: Replace the regex block with the flexible version**

In `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift`, replace lines 92-98 with:

```swift
    private static let forwardedRegex: NSRegularExpression? = {
        // Matches both the backend's `> Forwarded from @<login>\n\n…`
        // markdown-blockquote format and a future cleaner
        // `Forwarded from @<login>\n…` form. Capture group 1 = login.
        try? NSRegularExpression(
            pattern: #"^(?:>\s+)?Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n+"#,
            options: []
        )
    }()
```

The change is exactly:
- Pattern `^Forwarded` → `^(?:>\s+)?Forwarded` (optional non-capturing group for `>` + whitespace)
- Trailing `\n` → `\n+` (one-or-more newlines, so the BE's `\n\n` is fully consumed and doesn't leak into the body)
- Comment expanded to cover both formats

`parseForwarded`'s logic at lines 23-35 is unchanged: `match.range` covers the whole prefix including the trailing `\n+`, and `String(raw[fullRange.upperBound...])` becomes the body — empty for image-only forwards, the original body for text/caption forwards.

- [ ] **Step 3: Compile**

```bash
xcodebuild -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

Expected: ends with `** BUILD SUCCEEDED **`. If you see an error mentioning `forwardedRegex` or `NSRegularExpression`, the swift literal escape probably broke — re-paste the exact block from Step 2.

- [ ] **Step 4: Spot-check with a one-liner that exercises the new regex**

Create a temporary playground-style check via `swift -e` on the BE format. (Skip this if `swift -e` is unavailable in your environment — the manual sim test in Task 3 covers it.)

```bash
swift -e '
import Foundation
let raw = "> Forwarded from @ethan\n\nhello world"
let re = try! NSRegularExpression(pattern: #"^(?:>\s+)?Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n+"#)
if let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
   let nameR = Range(m.range(at: 1), in: raw),
   let fullR = Range(m.range, in: raw) {
    print("login=\(raw[nameR]) body=\(String(raw[fullR.upperBound...]))")
} else {
    print("no match")
}
'
```

Expected output: `login=ethan body=hello world`

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift
git commit -m "fix(ios): forwardedRegex matches BE's '> Forwarded from …' format

The backend emits forwarded messages with a markdown blockquote prefix
'> Forwarded from @user\n\n…' but the iOS parser only matched
'Forwarded from @user\n'. Result: the styled forwarded-from header in
ChatMessageView never fired and the literal prefix leaked into the
rendered body.

Regex now optionally accepts a leading '> ' and consumes one-or-more
trailing newlines, so existing legacy forwards in the DB and future
BE forwards both parse cleanly into (forwardedFrom, body).

Refs GitchatSH/gitchat-ios-native#73

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Extract `forwardedHeader(from:)` helper

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift` (add helper near line 366)

The existing inline HStack at `ChatMessageView.swift:493-504` is about to be referenced from a different position in the bubble VStack. Pulling it into a small `@ViewBuilder` helper keeps the VStack scannable, matches the file's established convention (see `inlineReplyQuote(for:)` at line 366 and the many `@ViewBuilder` helpers above it), and lets us reorder without copy-pasting styling constants.

- [ ] **Step 1: Locate `inlineReplyQuote` to confirm placement**

```bash
grep -n "private func inlineReplyQuote" GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
```

Expected output: `366:    private func inlineReplyQuote(for reply: ReplyPreview) -> some View {`

If the line number drifted, just locate it and adjust Step 2 to insert the new helper directly above `inlineReplyQuote`.

- [ ] **Step 2: Insert the helper directly above `inlineReplyQuote`**

In `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`, locate this exact block (line 365-366):

```swift
    @ViewBuilder
    private func inlineReplyQuote(for reply: ReplyPreview) -> some View {
```

Replace it with:

```swift
    @ViewBuilder
    private func forwardedHeader(from login: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.caption2.weight(.bold))
            Text("Forwarded from @\(login)")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isMe ? .white.opacity(0.85) : .secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func inlineReplyQuote(for reply: ReplyPreview) -> some View {
```

The `forwardedHeader` body is byte-for-byte identical to the inline block currently at lines 494-503 — only the wrapping changes.

- [ ] **Step 3: Compile (helper exists but isn't called yet — file should still build)**

```bash
xcodebuild -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The Swift compiler tolerates an unused private method on a struct, so this is a clean intermediate state.

If you see a warning like `'forwardedHeader' is unused`, that's fine — it'll be wired up in Task 3.

- [ ] **Step 4: Commit (intermediate refactor)**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
git commit -m "refactor(ios): extract forwardedHeader(from:) helper

Pull the inline 'Forwarded from @login' HStack out of the bubble VStack
into a @ViewBuilder helper. No behavior change — same icon, same fonts,
same padding, same isMe-keyed foreground. Sets up the call-site reorder
in the next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Hoist the forwarded header to the top of the bubble VStack

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift:480-504`

This is the wire-up: prepend the new helper call to the bubble VStack so forwarded bubbles render `header → attachment → senderName → body` (Telegram-style), and delete the old inline block at line 493-504 to avoid double-rendering. Non-forwarded bubbles are unchanged because the `if let from = parsed.forwardedFrom` guard never fires.

- [ ] **Step 1: Verify the current bubble VStack matches the spec's reference lines**

```bash
sed -n '480,505p' GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
```

Expected output (verbatim):

```
        let bubble = VStack(alignment: .leading, spacing: 0) {
            // Attachment inside bubble (when there's also text)
            if hasAttachment {
                attachmentContentUnclipped
            }
            if showSenderName {
                Text(message.sender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(message.sender.senderColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
            }
            if let from = parsed.forwardedFrom {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.caption2.weight(.bold))
                    Text("Forwarded from @\(from)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(isMe ? .white.opacity(0.85) : .secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            if showInlineReply, let reply = message.reply {
```

If the block has drifted, locate the equivalent VStack opening + the inline `if let from = parsed.forwardedFrom` block before continuing.

- [ ] **Step 2: Replace the VStack opening + inline forward block**

Replace exactly this 25-line region (the entire block printed in Step 1's expected output, ending just before `if showInlineReply, let reply = message.reply {`):

```swift
        let bubble = VStack(alignment: .leading, spacing: 0) {
            // Attachment inside bubble (when there's also text)
            if hasAttachment {
                attachmentContentUnclipped
            }
            if showSenderName {
                Text(message.sender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(message.sender.senderColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
            }
            if let from = parsed.forwardedFrom {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.caption2.weight(.bold))
                    Text("Forwarded from @\(from)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(isMe ? .white.opacity(0.85) : .secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
```

with this (note: forward header now renders FIRST; the original inline block is removed):

```swift
        let bubble = VStack(alignment: .leading, spacing: 0) {
            // Forwarded-from header sits at the top of the bubble so the
            // attached image / shared card / body all render below it,
            // matching Telegram's forward layout. The bubble overlay border
            // (further down) already keys off `parsed.forwardedFrom != nil`,
            // so no other layout change is needed.
            if let from = parsed.forwardedFrom {
                forwardedHeader(from: from)
            }
            // Attachment inside bubble (when there's also text)
            if hasAttachment {
                attachmentContentUnclipped
            }
            if showSenderName {
                Text(message.sender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(message.sender.senderColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
            }
```

What changed:
- New `if let from = parsed.forwardedFrom { forwardedHeader(from: from) }` block prepended at the top of the VStack, with a comment explaining the position.
- The original inline `if let from = parsed.forwardedFrom { HStack { … } }` block (the one that lived after `showSenderName`) is deleted entirely. Its styling now lives in `forwardedHeader(from:)` from Task 2.
- All other lines (`hasAttachment` → `attachmentContentUnclipped`, `showSenderName` → `Text(message.sender) …`) keep their original code byte-for-byte. The `showInlineReply` block that follows is untouched.

- [ ] **Step 3: Sanity check that the duplicate inline block is gone**

```bash
grep -c "arrowshape.turn.up.right.fill" GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
```

Expected output: `1` (only the helper from Task 2 references it). If you see `2`, the inline block in the VStack wasn't deleted — re-read Step 2 and remove it.

- [ ] **Step 4: Compile**

```bash
xcodebuild -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
git commit -m "feat(ios): render forwarded-from header above the attachment

Move the call site of forwardedHeader(from:) to the very top of the
bubble VStack, so forwarded image messages render as
header → image → caption (Telegram-style) instead of
image → header. The inline duplicate of the header is removed.

Non-forwarded bubbles are unchanged: the new block is gated on
parsed.forwardedFrom != nil. The bubble overlay border (line ~575)
also keys off the same value, so the existing styling continues to
fire.

Refs GitchatSH/gitchat-ios-native#73

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Manual simulator verification (the 7 spec scenarios)

**No code changes.** This is the verification gate before opening a PR. iOS has no XCTest target, so this is the only way to confirm the spec's acceptance criteria.

- [ ] **Step 1: Boot the simulator and launch GitchatIOS against dev backend**

Prefer the project's run script if present (per the recent commit history, `scripts/run-sim.sh --local` is the project pattern):

```bash
ls scripts/run-sim.sh 2>/dev/null && bash scripts/run-sim.sh
```

If no run script exists, do it by hand:

```bash
xcrun simctl boot "iPhone 16" 2>/dev/null || true
open -a Simulator
xcodebuild -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build/DerivedData build 2>&1 | tail -5
APP_PATH=$(find build/DerivedData/Build/Products -name "GitchatIOS.app" -type d | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted chat.git
```

Expected: app launches in the simulator, dev backend reachable.

- [ ] **Step 2: AC1 — Image-only forward**

Action: in any 1:1 chat, long-press an image-only message → Forward → pick a target → Send. Open the target chat.

Expected: bubble shows `↪ Forwarded from @<sender>` styled header at the top, image rendered below, NO `> Forwarded from …` plain text anywhere. Bordered overlay around the bubble.

If you see plain `> Forwarded from @user`: regex did not match. Re-check Task 1.
If header is below the image: VStack ordering wrong. Re-check Task 3 Step 3.

- [ ] **Step 3: AC2 — Image-with-caption forward**

Action: forward a message that has BOTH an image and caption text.

Expected: header at top, image, then caption text. No `>`. The caption is the original caption verbatim (no prefix bleed).

- [ ] **Step 4: AC3 — Text-only forward**

Action: forward a text-only message (no attachment).

Expected: header at top, body text below. Bubble has the bordered overlay.

- [ ] **Step 5: AC4 — Forward with `@login` mention card**

Action: forward a message whose body contains an `@login` mention that auto-renders as a profile card preview (e.g., `@0xmrpeter`).

Expected: header at top, profile card embedded inline, NO duplicate `> Forwarded from …` text under the card.

This is the bug from the user's screenshot 3. If the card still has stray prefix text under it, the regex consumed only some of the prefix — re-check that the regex pattern uses `\n+` (not `\n`).

- [ ] **Step 6: AC5 — Legacy forwards retroactively re-render**

Action: open a chat that already contains forwards from BEFORE this change (e.g., the screenshot from issue #73 reproduces this). Scroll to those bubbles.

Expected: each legacy forward now shows the styled header at the top instead of the literal `> Forwarded from …` body text.

- [ ] **Step 7: AC6 — Non-forwarded messages unchanged**

Action: scroll to several non-forwarded messages (regular text, image, image+caption).

Expected: identical to current behavior. No bordered overlay. No header. Image-on-top layout for caption messages. Sender name in correct position for group messages.

- [ ] **Step 8: AC7 — Bordered overlay scoped to forwards**

Action: visually compare a forwarded bubble to an adjacent non-forwarded bubble.

Expected: only the forwarded bubble has the subtle `Color.white.opacity(0.3)` (outgoing) or `Color.secondary.opacity(0.3)` (incoming) border. Non-forwarded bubbles have `Color.clear` (no visible stroke).

- [ ] **Step 9: AC8 — Group-chat incoming forward**

Action: in a group chat, have a non-`me` user forward an image to the group. View the resulting bubble.

Expected: `forwardedHeader` at the very top of the bubble, then `attachmentContentUnclipped`, then `senderName` (the forwarder's `@login`), then any caption. This is intentionally not a perfect Telegram match (Telegram puts senderName above the forward header) — the spec accepts this tradeoff to avoid touching non-forwarded group-chat layout.

- [ ] **Step 10: Catalyst smoke (if available)**

If you have access to a Mac Catalyst build:

```bash
xcodebuild -scheme GitchatIOS -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -5
```

Run the Catalyst app and repeat AC1 (image-only forward) and AC4 (mention card) — the most layout-sensitive cases.

- [ ] **Step 11: Polish loop (only if needed)**

If any padding looks visually off (e.g., header too tight against the image edge), tighten or loosen `.padding(.bottom, 4)` inside `forwardedHeader(from:)` to taste. Default is 4. Try 6 or 2 and re-build. Commit any polish change as a separate small commit:

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
git commit -m "polish(ios): tighten forwardedHeader bottom padding to N pt

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

If no polish is needed, skip this step.

---

## Task 5: Open the PR

**No code changes.** Push the branch and open a PR against `main`.

- [ ] **Step 1: Sanity-check the branch against `origin/main`**

```bash
git log --oneline origin/main..HEAD
```

Expected: 2 or 3 commits (regex fix, helper extract, header reorder, optional polish), each with a clear message.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/telegram-forward-header
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --repo GitchatSH/gitchat-ios-native --base main --head feat/telegram-forward-header \
  --title "feat(ios): Telegram-style forwarded-message header" \
  --body "$(cat <<'EOF'
## Summary

- iOS forwarded bubbles now render with the existing styled header at the top of the bubble, with the attachment / shared card / body below — matching Telegram's forward layout.
- Two iOS-only file edits (no backend / schema / DTO / extension changes). Pairs with the BE fix in GitchatSH/gitchat-webapp#70 that ships images on forward.
- Legacy forwards already in conversation history retroactively render with the new header on next read; no migration.

## Changes

- \`ChatMessageText.swift\` — \`forwardedRegex\` flexibly matches both BE's \`> Forwarded from @user\\n\\n…\` blockquote format and a future cleaner \`Forwarded from @user\\n…\` form. Capture group unchanged.
- \`ChatMessageView.swift\` — extract the inline forwarded-header HStack into a \`@ViewBuilder forwardedHeader(from:)\` helper, then move the call site to the top of the bubble VStack so the header sits above the attachment.

## Test plan (manual sim — no XCTest target per CLAUDE.md)

- [x] Image-only forward: header at top, image below, no '>' text
- [x] Image-with-caption forward: header at top, image, caption
- [x] Text-only forward: header at top, body below
- [x] @login mention card forward: header at top, card, no duplicate prefix
- [x] Legacy forwards (pre-change) retroactively render with the new header
- [x] Non-forwarded messages unchanged
- [x] Bordered overlay still scoped to forwarded bubbles
- [x] Group-chat incoming forward: header → image → senderName → body (intentional tradeoff documented in spec AC8)
- [ ] Catalyst smoke (if applicable)

Spec: [\`docs/superpowers/specs/2026-04-29-telegram-style-forward-header.md\`](docs/superpowers/specs/2026-04-29-telegram-style-forward-header.md)
Plan: [\`docs/superpowers/plans/2026-04-29-telegram-style-forward-header.md\`](docs/superpowers/plans/2026-04-29-telegram-style-forward-header.md)

Refs GitchatSH/gitchat-ios-native#73

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: prints the PR URL.

- [ ] **Step 4: Cross-link from issue #73**

```bash
gh issue comment 73 --repo GitchatSH/gitchat-ios-native --body "iOS UI follow-up — Telegram-style header rendering: <PR URL from previous step>. Pairs with the BE fix in GitchatSH/gitchat-webapp#70."
```

Replace `<PR URL>` with the URL printed in Step 3.

---

## Verification gate before declaring done

- [ ] Both Swift files committed on `feat/telegram-forward-header`.
- [ ] `xcodebuild build` succeeds locally on the latest commit.
- [ ] All 7 manual scenarios in Task 4 passed visually on the simulator.
- [ ] PR opened against `main` with the test-plan checklist filled in.
- [ ] Issue #73 has a comment linking to the iOS PR.

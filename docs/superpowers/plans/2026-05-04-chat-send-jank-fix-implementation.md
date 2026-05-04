# Chat Send Jank Fix (#104) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (this branch is being inline-executed by the same session that authored the plan; no fresh subagent dispatch). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement b1 from `docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md` — surgical fix for issue #104 covering (a) data parity in `OutboxStore.toMessage` and (b) settle-aware scroll replacing the triple-snap from PR #103.

**Architecture:** Two independent surgical edits. Part 1 expands `OutboxStore.toMessage` to populate `client_message_id` and `attachments` so the optimistic Message and the server-confirmed Message render at identical heights for text + image sends. Part 2 replaces the open-loop triple-snap in `ChatMessagesList.updateUIView` with a closed-loop KVO observer on `tableView.contentSize`, scoped to a 300ms anchored window with stable/deadline/scroll-up stop conditions.

**Tech Stack:** Swift 5.9, UIKit (UITableView, NSKeyValueObservation), SwiftUI (UIHostingConfiguration), no XCTest target → verification = `xcodebuild` compile + manual scenarios.

**Pre-flight:**
- On branch `fix/issue-104-chat-send-jank` (already created).
- Spec docs already committed (see `git log -1`).

---

## File Structure

| File | Role | Status |
|---|---|---|
| `GitchatIOS/Core/OutboxStore.swift` | Singleton outbox store; owner of `PendingMessage` and `toMessage` projection | MODIFY (~15 lines added in `toMessage`) |
| `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` | UITableView-backed chat list; owner of `Coordinator` and `scrollIfNeeded` | MODIFY (replace triple-snap, add anchor methods + 4 properties on Coordinator + 1 static flag) |

No new files. No `xcodegen generate` needed.

---

## Task 1: Data Parity in `OutboxStore.toMessage`

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift:531-545`

- [ ] **Step 1.1: Locate current `toMessage` implementation**

Verify `OutboxStore.toMessage(_ p: PendingMessage) -> Message` at lines 531-545 has the shape the spec describes (no `client_message_id`, no `attachments`).

Run: `grep -n "func toMessage" GitchatIOS/Core/OutboxStore.swift`
Expected output: `531:    func toMessage(_ p: PendingMessage) -> Message {`

- [ ] **Step 1.2: Confirm `MessageAttachment` initializer shape**

Open `GitchatIOS/Core/Models/Models.swift` and confirm `MessageAttachment` has init with `attachment_id`, `url`, `type`, `filename`, `mime_type`, `width`, `height` (matching `Message.optimistic` factory at line 717).

Run: `grep -n "struct MessageAttachment\|init(" GitchatIOS/Core/Models/Models.swift | head -20`
Expected: a public/internal init with the 7 fields above visible.

- [ ] **Step 1.3: Replace `toMessage` body**

Edit `GitchatIOS/Core/OutboxStore.swift`:

Old (lines 531-545):
```swift
    func toMessage(_ p: PendingMessage) -> Message {
        Message(
            id: PendingMessage.optimisticID(for: p.clientMessageID),
            conversation_id: p.conversationID,
            sender: AuthStore.shared.login ?? "me",
            sender_avatar: nil,
            content: p.content,
            created_at: Self.iso8601.string(from: p.createdAt),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: p.replyToID
        )
    }
```

New:
```swift
    func toMessage(_ p: PendingMessage) -> Message {
        // Map PendingAttachment → MessageAttachment so the optimistic
        // bubble renders thumbnails at the same intrinsic height as
        // the server-confirmed bubble. Pre-#104, these were nil →
        // optimistic bubble was caption-only → big visual resize when
        // server confirmed. See spec 2026-05-04-chat-send-jank-fix-design.
        let mappedAttachments: [MessageAttachment]? = p.attachments.isEmpty ? nil :
            p.attachments.map { att in
                MessageAttachment(
                    attachment_id: att.clientAttachmentID,
                    url: att.uploaded?.url ?? "",
                    type: att.mimeType.hasPrefix("image/") ? "image" : "file",
                    filename: nil,
                    mime_type: att.mimeType,
                    width: att.width,
                    height: att.height
                )
            }
        return Message(
            id: PendingMessage.optimisticID(for: p.clientMessageID),
            client_message_id: p.clientMessageID,
            conversation_id: p.conversationID,
            sender: AuthStore.shared.login ?? "me",
            sender_avatar: nil,
            content: p.content,
            created_at: Self.iso8601.string(from: p.createdAt),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: p.replyToID,
            reply: nil,
            attachments: mappedAttachments,
            unsent_at: nil,
            reactionRows: nil
        )
    }
```

- [ ] **Step 1.4: Verify Message initializer matches**

Confirm the 16-arg `Message.init(...)` accepts `client_message_id`, `reply`, `attachments`, `unsent_at`, `reactionRows` named parameters in that order. Refer to `Models.swift:373-385` (the public init signature).

Run: `sed -n '370,400p' GitchatIOS/Core/Models/Models.swift`
Expected: parameter list matches the names + order in the snippet above.

If parameter order differs (e.g. `reactionRows` comes before `attachments`), adjust the call site to match Swift's `Message.init`.

- [ ] **Step 1.5: Compile gate (iOS simulator)**

Run:
```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme "GitchatIOS local" \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -configuration Debug build 2>&1 | tail -30
```
Expected: `BUILD SUCCEEDED`. No new warnings.

- [ ] **Step 1.6: Compile gate (Mac Catalyst)**

Run:
```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme "GitchatIOS local" \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug build 2>&1 | tail -30
```
Expected: `BUILD SUCCEEDED`.

If signing errors block Catalyst build, retry with `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` appended.

---

## Task 2: Settle-Aware Anchored Scroll on Coordinator

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` — `updateUIView` block at lines 296-348 + `Coordinator` class additions.

- [ ] **Step 2.1: Add stored properties + flag on `Coordinator`**

Insert after the existing `lastScrollToBottomToken` line (around `ChatMessagesList.swift:484`):

```swift
        // MARK: Anchored scroll-to-bottom (settle-aware, replaces #103 triple-snap)

        /// Toggle for verification logging. Set to `true` locally to capture
        /// AC1-4 acceptance logs (see spec 2026-05-04-chat-send-jank-fix-design
        /// §4.1); MUST be `false` before merging to keep production console clean.
        private static let kAnchorLog = false

        private var anchorObservation: NSKeyValueObservation?
        private var anchorDeadline: Date?
        private var anchorStableTicks: Int = 0
        private var anchorStartedAt: Date?
```

(The exact line number depends on current file state — insert in the "Stored properties" block of `Coordinator`, after `lastScrollToBottomToken` and before `var lastUnreadCount`.)

- [ ] **Step 2.2: Add `beginAnchoredScrollToBottom(in:)` and `cancelAnchor(reason:)` methods**

Insert as new methods on `Coordinator`, after `scrollToBottom(in:animated:)` (around line 883):

```swift
        /// Replaces the open-loop triple-snap from PR #103. Snaps offset to
        /// `-contentInset.top` (rotated table's visual bottom), then KVO-observes
        /// `contentSize` and re-snaps on every change while user is at-bottom.
        /// Stops on:
        ///   - 2 consecutive contentSize-stable KVO ticks, or
        ///   - 300ms hard deadline, or
        ///   - User scrolled up (offset crossed at-bottom threshold), or
        ///   - A new send arrives (rapid-send: previous window is "superseded").
        ///
        /// See `docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md`.
        func beginAnchoredScrollToBottom(in tv: UITableView) {
            cancelAnchor(reason: "superseded")

            let snap: () -> Void = { [weak tv] in
                guard let tv else { return }
                tv.layoutIfNeeded()
                tv.setContentOffset(CGPoint(x: 0, y: -tv.contentInset.top), animated: false)
            }
            snap()

            let started = Date()
            anchorStartedAt = started
            anchorDeadline = started.addingTimeInterval(0.3)
            anchorStableTicks = 0
            if Self.kAnchorLog {
                NSLog("[anchor] start offset=%.2f cs.h=%.2f",
                      tv.contentOffset.y, tv.contentSize.height)
            }
            anchorObservation = tv.observe(\.contentSize, options: [.old, .new]) { [weak self, weak tv] _, change in
                guard let self, let tv else { return }
                if let dl = self.anchorDeadline, Date() > dl {
                    self.cancelAnchor(reason: "deadline")
                    return
                }
                let atBottomThreshold = -tv.contentInset.top + 120
                let atBottom = tv.contentOffset.y < atBottomThreshold
                guard atBottom else {
                    self.cancelAnchor(reason: "user-scrolled-up")
                    return
                }
                if let old = change.oldValue, let new = change.newValue,
                   abs(old.height - new.height) < 0.5 {
                    self.anchorStableTicks += 1
                    if self.anchorStableTicks >= 2 {
                        self.cancelAnchor(reason: "stable")
                    }
                    return
                }
                self.anchorStableTicks = 0
                snap()
                if Self.kAnchorLog, let old = change.oldValue, let new = change.newValue {
                    NSLog("[anchor] kvo cs.h %.2f→%.2f offset=%.2f stable=%d",
                          old.height, new.height, tv.contentOffset.y, self.anchorStableTicks)
                }
            }
        }

        private func cancelAnchor(reason: String) {
            if Self.kAnchorLog, anchorObservation != nil, let started = anchorStartedAt {
                let durMs = Date().timeIntervalSince(started) * 1000
                NSLog("[anchor] end reason=%@ duration=%.0fms", reason, durMs)
            }
            anchorObservation?.invalidate()
            anchorObservation = nil
            anchorDeadline = nil
            anchorStableTicks = 0
            anchorStartedAt = nil
        }
```

- [ ] **Step 2.3: Replace `scrollIfNeeded` block in `updateUIView`**

In `updateUIView` (around lines 311-329), replace the existing `scrollIfNeeded` definition:

Old:
```swift
        let scrollIfNeeded: () -> Void = { [weak tv] in
            guard needsScroll, let tv = tv else { return }
            let snap: () -> Void = {
                tv.layoutIfNeeded()
                let target = CGPoint(x: 0, y: -tv.contentInset.top)
                tv.setContentOffset(target, animated: false)
            }
            snap()
            // Re-assert on the next two runloop ticks. Cell self-sizing
            // for UIHostingConfiguration can resolve over multiple layout
            // passes after the diff completion fires; a single
            // setContentOffset is not sticky against those late shifts.
            DispatchQueue.main.async {
                snap()
                DispatchQueue.main.async {
                    snap()
                }
            }
        }
```

New:
```swift
        let scrollIfNeeded: () -> Void = { [weak tv, weak coord] in
            guard needsScroll, let tv = tv, let coord = coord else { return }
            // Replaces #103's triple-snap with a closed-loop KVO observer
            // on contentSize so we re-anchor on every late UIHostingConfiguration
            // self-sizing pass instead of just at fixed runloop ticks.
            // See spec 2026-05-04-chat-send-jank-fix-design §3.
            coord.beginAnchoredScrollToBottom(in: tv)
        }
```

Note: `coord` is `context.coordinator` — already in scope from `let coord = context.coordinator` at the top of `updateUIView` (line 232). The capture list adds `[weak coord]` to avoid retain cycle.

- [ ] **Step 2.4: Compile gate (iOS simulator)**

Same command as Step 1.5. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2.5: Compile gate (Mac Catalyst)**

Same command as Step 1.6. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2.6: Grep for residual triple-snap reference**

Run:
```bash
grep -n "Re-assert on the next two runloop ticks\|DispatchQueue.main.async {.*\\n.*snap()" GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift
```
Expected: no matches (the old comment + nested asyncs should be fully replaced).

---

## Task 3: Render-Path Sanity Probe for Empty-URL Attachments

**Files:**
- Read-only: identify the SwiftUI view that renders `MessageAttachment.url`.

This is a verification task, not a code change unless we discover a problem.

- [ ] **Step 3.1: Identify the attachment renderer**

Run:
```bash
grep -rn "MessageAttachment\|attachment\.url\|att\.url" GitchatIOS/Features --include="*.swift" | grep -v Tests | head -20
```
Note the file(s) that consume `MessageAttachment.url` for rendering.

- [ ] **Step 3.2: Inspect handling of empty `url` string**

Open the file from Step 3.1. Trace what happens when `url == ""`:
- Does `URL(string: "")` get `nil` returned and is that handled?
- Does the image loader (`AsyncImage`, `ImageCache.shared`, etc.) silently no-op on empty?
- Is there a fallback to local-data rendering?

If render path is robust (no crash, no broken-image icon for empty url), proceed to Step 3.3.

If render path will crash or show an obvious broken-image glyph, STOP and add a defensive guard:
```swift
if let urlString = attachment.url, !urlString.isEmpty,
   let parsed = URL(string: urlString) { /* render */ } else { /* skip */ }
```
Apply at the renderer site. This becomes a sub-task; follow the same compile-gate + commit cadence.

- [ ] **Step 3.3: Document finding**

Whether path was robust or required a guard, append a one-paragraph summary to the spec under §2.4:

```bash
# Edit docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md
# Add a "### 2.5 Empty-URL probe finding" subsection summarizing what
# Step 3.1-3.2 found.
```

If no change was needed, the paragraph documents that fact so future readers don't re-investigate.

---

## Task 4: Commit Implementation

- [ ] **Step 4.1: Stage changes**

Run:
```bash
git status
git diff --stat
```
Expected: 2-3 files changed (`OutboxStore.swift`, `ChatMessagesList.swift`, possibly the design doc spec from Task 3.3).

- [ ] **Step 4.2: Create commit**

Run:
```bash
git add GitchatIOS/Core/OutboxStore.swift \
        GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift \
        docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md
git commit -m "$(cat <<'EOF'
fix(ios): chat composer jank during send (#104)

Two surgical edits as described in
docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md:

1. OutboxStore.toMessage now populates client_message_id and maps
   PendingAttachment → MessageAttachment so optimistic and server-
   confirmed bubbles render at identical intrinsic heights for text
   + image sends. Prevents the bubble-resize jump observed when the
   diffable apply swaps "local-cmid" for "server-id".

2. ChatMessagesList.scrollIfNeeded replaces #103's open-loop triple-
   snap with a closed-loop KVO observer on tv.contentSize. Inside a
   300ms anchored window, every contentSize change re-snaps offset
   to -contentInset.top while the user remains at-bottom. Stops on
   2 stable ticks, deadline, user-scroll-up, or supersession by a
   new send. Eliminates the multi-tick visible jump and the rapid-
   send "overlapping snap sequences" chaos noted in the issue.

Reply-preview parity is intentionally out of scope (would require
expanding PendingMessage Codable + on-disk migration); tracked as
v1.1 follow-up. Rotated-table replacement is captured separately in
docs/superpowers/specs/2026-05-04-chat-list-anchored-collection-design.md
as a Level 2 exploration awaiting review.

Verification log gate (`Coordinator.kAnchorLog`) ships as `false`.
Flip locally to `true` to capture AC1-4 logs from the spec when
running manual scenarios.

Fixes #104

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4.3: Verify commit**

Run: `git log --oneline -2`
Expected: top entry `fix(ios): chat composer jank during send (#104)`, second entry the spec commit `97fda1f docs(spec): chat send jank fix...`.

---

## Task 5: Push Branch & Open PR

- [ ] **Step 5.1: Push branch**

Run:
```bash
git push -u origin fix/issue-104-chat-send-jank
```
Expected: branch published; pull-request URL printed.

- [ ] **Step 5.2: Open PR**

Run:
```bash
gh pr create \
  --title "fix(ios): chat composer jank during send (#104)" \
  --body "$(cat <<'EOF'
## Summary

Surgical fix for [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104) — visible jank/jumping when sending messages, especially in rapid succession. Follow-up to PR #103.

Two independent edits, both described in the design spec (`docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md`):

1. **Data parity** in `OutboxStore.toMessage` — now populates `client_message_id` and maps `PendingAttachment → MessageAttachment`. Pending and server-confirmed bubbles render at identical intrinsic heights for text + image sends, so the diffable swap from `local-cmid` → `server-id` is height-stable.
2. **Settle-aware scroll** in `ChatMessagesList` — replaces #103's triple-snap with a 300ms-windowed KVO observer on `contentSize`. Re-anchors offset on every late `UIHostingConfiguration` self-sizing pass while the user remains at-bottom; stops on 2 stable ticks, deadline, user-scroll-up, or supersession by a new send.

## Out of scope (tracked separately)

- **Reply-preview parity** — requires expanding `PendingMessage` Codable + on-disk migration of `outbox-pending.json` for users with failed messages. Will revisit as v1.1.
- **Rotated UITableView replacement** (issue's direction #4) — explored in companion spec `2026-05-04-chat-list-anchored-collection-design.md`, exploration only, awaiting review.

## Test plan

### Compile gate ✅ (run during dev)
- [ ] `xcodebuild` for `GitchatIOS local` scheme — iOS Simulator → BUILD SUCCEEDED
- [ ] `xcodebuild` for `GitchatIOS local` scheme — Mac Catalyst → BUILD SUCCEEDED

### Manual scenarios (user verification)

**Both on iOS simulator AND Mac Catalyst:**

- [ ] **S1** Type "hello" → Return while at bottom — bubble lands at bottom with NO visible jump on server confirm.
- [ ] **S2** Rapid send 10× short text (Return-Return-Return…) — all bubbles in tap order, no chaotic re-arrange.
- [ ] **S3** Send a photo + caption — pending bubble shows thumbnail (b1 data parity); server confirm = no resize.
- [ ] **S4** Reply to a message then send — pending text-only, server adds quote-preview (small reflow expected — known limitation).
- [ ] **S5** Scroll up mid-list, inbound message arrives — does NOT yank to bottom (anchor at-bottom guard).
- [ ] **S6** Send → back out immediately → re-enter — pending bubble persists, swap is smooth.
- [ ] **S7** Failed send → tap Retry — scrolls to bottom correctly.
- [ ] **S8** Mac Catalyst: send via Return AND via send-arrow click — both smooth.

### Quantitative AC verification (optional)

To capture AC1-4 from the spec §4.1, flip `kAnchorLog` to `true` in `ChatMessagesList.swift` (search the file for the constant), rebuild, run S1/S2/S3, and read the `[anchor] start | kvo | end` lines from `xcrun simctl spawn <udid> log stream --process Gitchat`. Verify:
- AC1: `end` always followed by `offset == -contentInset.top ± 0.5pt`
- AC2: every `[anchor] end` has `duration ≤ 300ms`
- AC3: every `kvo` line with cs.h delta ≥ 0.5pt has `offset = -inset.top` in the same line
- AC4: rapid-send shows `start … end reason=superseded … start` interleaving (no two `start` without an `end` between)

**Before merging:** flip `kAnchorLog` back to `false` (or verify it never moved off `false`).

## Risk

Low surgical scope. KVO on `UIScrollView.contentSize` is a pattern used by many iOS chat apps; observer is short-lived (300ms ceiling) and self-cancels. No `PendingMessage` schema change → no on-disk migration needed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 5.3: Capture PR URL**

Save the PR URL into the final summary message back to the user. Do not request review automatically; user will review on wake-up.

---

## Self-Review Notes

**Spec coverage:** Each section of the spec maps to a task above:
- §2 (data parity) → Task 1
- §3 (settle-aware scroll) → Task 2
- §2.4 (empty-URL edge case) → Task 3
- §4.3 (compile gate) → Steps 1.5/1.6/2.4/2.5
- §4.1/4.2 (AC1-4 + manual S1-S8) → covered in PR test-plan checklist (user verification)

**Type consistency:** `beginAnchoredScrollToBottom(in:)` and `cancelAnchor(reason:)` named consistently in both Step 2.2 and Step 2.3. KVO `tableView.contentSize` keypath consistent. `kAnchorLog` static constant referenced consistently.

**Placeholder scan:** No TBD/TODO. Code blocks are complete. Test commands are exact.

**Caveats inherited from spec:**
- Task 3 may produce a small downstream fix if attachment renderer doesn't handle empty URL. That's surfaced by the probe; not pre-decided.
- Manual scenarios S1-S8 cannot be executed by the planning session — user must run on wake-up.

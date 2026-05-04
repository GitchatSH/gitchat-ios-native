# Chat Send Jank Fix (#104) — Design Spec

**Date:** 2026-05-04
**Author:** EthanMiller0x — drafted via `superpowers:brainstorming`
**Status:** Approved (verbal), proceeding to implementation
**Target branch:** `fix/issue-104-chat-send-jank` off `main`
**Issue:** [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104) — follow-up to [#102](https://github.com/GitchatSH/gitchat-ios-native/issues/102) / PR [#103](https://github.com/GitchatSH/gitchat-ios-native/pull/103)
**Companion exploration:** [`2026-05-04-chat-list-anchored-collection-design.md`](2026-05-04-chat-list-anchored-collection-design.md) (Level 2 — out of scope here)
**Depends on (must read):** [`docs/architecture/optimistic-send-pipeline.md`](../../architecture/optimistic-send-pipeline.md)

---

## 0. One-minute summary

After PR #103 placed the bubble at the right position (no more "behind composer"), each send still showed a small visible jump. Specifically: #103's `scrollIfNeeded` snaps `setContentOffset(animated:false)` three times across three runloop ticks to win the race against `UIHostingConfiguration` cell-sizing. Between those snaps, `contentSize` shifts (verification log from #103: `4092 → 4051.5`) → bubble visibly jumps. On rapid-send, multiple snap sequences overlap = chaos.

The fix has two independent surgical parts:

| # | Part | File |
|---|---|---|
| 1 | **Data parity** in `OutboxStore.toMessage` (populate `client_message_id`, `attachments`) — pending bubble and server-confirmed bubble render bit-identical for text + attachments | `GitchatIOS/Core/OutboxStore.swift` |
| 2 | **Settle-aware scroll** replacing the triple-snap — KVO on `tableView.contentSize` within a ≤ 300ms window; re-anchor offset on every contentSize change while user is at-bottom; auto-stops on stable / deadline | `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` |

Reply-quote pending → server-confirmed transition still has a small reflow (would require expanding the `PendingMessage` Codable schema → on-disk migration) → **out of scope for b1**, tracked as v1.1.

Fully out of scope: replacing the rotated UITableView. b1 does not eliminate the entire class of bugs described in direction #4 of the issue; that's covered by Level 2 in the companion exploration.

---

## 1. Diagnosis

### 1.1 Why #103 still janks

The triple-snap is **open-loop**: it pins offset at three discrete moments (`apply-completion`, `runloop+1`, `runloop+2`). Between those points, UIKit/SwiftUI may change `contentSize` and #103's mechanism cannot react. Consequences:
- The newly-inserted cell (server-id) goes through multiple `UIHostingConfiguration` self-sizing passes — its intrinsic size only stabilizes after several frames, not immediately after diff completion.
- The just-deleted cell (local-cmid) also triggers a contentSize shrink as UITableView reclaims the row height.
- Under rapid-send, multiple `scrollIfNeeded` chains run concurrently — each has 3 ticks, none cancels the previous → "multiple overlapping snap sequences" as the issue describes.

### 1.2 Secondary cause — data parity gap

`OutboxStore.toMessage` (`OutboxStore.swift:531`) only populates a subset of `Message`:
```swift
Message(id: ..., conversation_id: ..., sender: ..., sender_avatar: nil,
        content: p.content, created_at: ..., edited_at: nil,
        reactions: nil, attachment_url: nil, type: "user", reply_to_id: p.replyToID)
```
**Missing:** `client_message_id`, `attachments`, `reply`, `reactionRows`, `unsent_at`.

For text-only sends, both pending and server-confirmed have these fields = nil, so no reflow. But:
- **Attachments:** `PendingMessage.attachments: [PendingAttachment]` already carries data + mime + w/h. The pending bubble currently doesn't draw a thumbnail; the server-confirmed bubble does → large resize (5–10× height) on swap. **Fixed in b1.**
- **Reply preview:** `PendingMessage` only has `replyToID: String?`, no `ReplyPreview` snapshot → quote-preview only appears after server confirm → small reflow (~30–50pt). **Out of scope for b1** (would require expanding PendingMessage Codable + on-disk migration).

### 1.3 Acceptance from the issue

> Sends look smooth (Telegram / iMessage parity): the bubble appears at the bottom and stays there without visible offset adjustment.

Concretized into measurable AC in §4.

---

## 2. Part 1 — Data parity in `OutboxStore.toMessage`

### 2.1 Change

```swift
func toMessage(_ p: PendingMessage) -> Message {
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
        client_message_id: p.clientMessageID,           // NEW
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
        reply: nil,                                     // out-of-scope b1 (Level 2)
        attachments: mappedAttachments,                 // NEW
        unsent_at: nil,
        reactionRows: nil
    )
}
```

The pattern follows `Message.optimistic(...)` at `Models.swift:709` (already the standard for the legacy flow), avoiding any reinvention of the mapping.

### 2.2 Invariants check

Cross-checked against `optimistic-send-pipeline.md`:
- **Inv-1** (pending only in OutboxStore, server only in vm.messages, merge in `visibleMessages`): ✅ — pending is still rendered from the store; only the projection to Message changes.
- **Inv-4** (pre-stamp createdAt with client tap time): ✅ — still uses `Self.iso8601.string(from: p.createdAt)`.
- **Inv-5** (ms precision): ✅ — `Self.iso8601` already configured with `.withFractionalSeconds`.
- **Inv-6** (don't touch `seenIds` from executeSend success path): n/a, the send flow is unchanged.

### 2.3 Schema/migration

No change to `PendingMessage` Codable → `outbox-pending.json` on user devices decodes automatically. No migration required.

### 2.4 Edge cases

- **Empty attachments** (text-only): `mappedAttachments == nil` — identical to the previous behavior → text-only behavior unchanged.
- **Attachment not yet uploaded** (`att.uploaded == nil`): mapped with `url: ""`. The UI render path already accepts an empty url (see §2.5 finding). Cell height is still correct because `ChatAttachmentsGrid` sets `.frame(width:height:)` deterministically based on attachment count + bubble maxWidth, independent of whether the URL has resolved.
- **Attachment already uploaded** (`att.uploaded != nil`): uses `uploaded.url` — pending bubble shows the correct URL, swapping to the server-confirmed Message uses the same URL → no reflow.

### 2.5 Empty-URL probe finding (Task 3 result)

Probe on 2026-05-04: `ChatAttachmentsGrid` (`GitchatIOS/Features/Conversations/ChatDetail/Message/ChatAttachmentsGrid.swift:69-98`) calls `URL(string: a.url)` and passes the result into `CachedAsyncImage(url:)`. An empty string → `URL(string: "")` returns `nil` → `CachedAsyncImage` does not attempt to load and renders a filled placeholder. The `isUploading` flag (set via `message.id.hasPrefix("local-")` in `ChatMessageView.swift:433/455`) overlays a ProgressView on top of the placeholder for the pending state. The render path does not crash on empty url. **However**, §2.6 below shows this is a half-fix — the placeholder→image transition when the real URL arrives still causes jank.

### 2.6 Image-jank follow-up (Mac Catalyst regression report 2026-05-04)

After the initial b1 was merged, EthanMiller0x tested on Mac Catalyst and reported: sending an image (with or without caption) still felt like a jump when the upload completed. Re-investigation surfaced:

**Root cause #1 (cell-height shift, standalone path only):**
`ChatAttachmentsGrid.one(applyClip: true)` has no fixed `.frame(width:height:)`. `CachedAsyncImage`'s placeholder renders `Color.frame(width: side, height: side)` as a square (`side = min(260, 320) = 260`). Once the image loads, `.frame(width: fitted.w, height: fitted.h)` sizes by the actual aspect ratio (e.g., 240×320 portrait, 260×146 landscape). The cell's intrinsic height changes → contentSize shift → unanchored jump.

**Root cause #2 (placeholder→image visual flash, both paths):**
On a slow network (Mac Catalyst real Wi-Fi vs iOS sim local cache), `CachedAsyncImage`'s `.task(id: url)` takes a few hundred milliseconds to seconds to fetch + decode. When the local→server ID flip happens, the cell rebuilds with the new url → CachedAsyncImage state resets → placeholder shows up again while the network fetch runs → user sees a flash. The iOS simulator doesn't show this because the local cache hits or the fetch is instant.

**Fix:**
1. **Photo picker captures pixel dims** (`ChatDetailView.swift:781-792`): set `width: Int(img.size.width * img.scale)`, `height: ...` instead of nil. BE-format pixel dimensions; consumed by (3) below.
2. **OutboxStore transient temp-file map** (`OutboxStore.swift`):
   - `localPreviewPaths: [clientAttachmentID: URL]` (in-memory only, not Codable, not persisted).
   - `enqueue` calls `registerLocalPreview` for every image attachment → writes `sourceData` to `tmp/gitchat-outbox-previews/<id>.<ext>`, stores the URL in the map.
   - `markDelivered`/`discard`/`cancel` call `cleanupLocalPreviews` to remove the file + drop the entry.
3. **`toMessage` URL preference** (`OutboxStore.swift:531`): `att.uploaded?.url ?? localPreviewPaths[att.id]?.absoluteString ?? ""`. The pending bubble uses a `file://` URL; CachedAsyncImage's `load()` takes the `if url.isFileURL` branch → `UIImage(contentsOfFile:)` synchronous → image renders without going through the placeholder.
4. **ImageCache prime after upload** (`OutboxStore.executeSend`): right after `att.uploaded = ref` is set, call `ImageCache.shared.store(uiImage, for: serverURL)` + `storeRawData(...)`. Later, when the ID flips → cell rebuilds with the server URL → CachedAsyncImage `load()` → `ImageCache.shared.image(for:)` cache hit immediately → no network fetch, no placeholder flash.
5. **`ChatAttachmentsGrid.one(applyClip: true)` frame wrap** (`ChatAttachmentsGrid.swift:101`): compute fittedSize from `a.width/a.height` (the same aspect-fit math as CachedAsyncImage's loaded-image branch), wrap the ZStack in `.frame(width: fittedSize?.width, height: fittedSize?.height)`. If dims are nil (legacy messages from before this fix) → `.frame(width: nil, height: nil)` is identity, behavior unchanged.

**Edge cases:**
- File write failure (full disk): the `localPreviewPaths` map has no entry → falls back to URL = "" → placeholder. Acceptable.
- App restart during a failed-message retry: the temp directory may have been cleaned by the OS (sandbox `/tmp/...` usually persists across restart but it's not guaranteed) → file missing → CachedAsyncImage placeholder shows briefly → on ID flip, the cache prime didn't happen in this session → falls back to a normal network fetch. Acceptable for the rare retry-after-restart case.
- Non-image attachment (file/document): the `mimeType.hasPrefix("image/")` guard skips both registration and cache priming → behavior unchanged.

---

## 3. Part 2 — Settle-aware scroll replacing the triple-snap

### 3.1 Mechanism

Replace the `scrollIfNeeded` block (`ChatMessagesList.swift:311–329`) with methods on the Coordinator:

```swift
// MARK: Anchored scroll (settle-aware)

/// Toggle for verification logging. Set to false before merging.
private static let kAnchorLog = false

private var anchorObservation: NSKeyValueObservation?
private var anchorDeadline: Date?
private var anchorStableTicks: Int = 0
private var anchorStartedAt: Date?

func beginAnchoredScrollToBottom(in tv: UITableView) {
    cancelAnchor(reason: "superseded")  // rapid-send: cancel old window before setting up a new one

    let snap: () -> Void = { [weak tv] in
        guard let tv else { return }
        tv.layoutIfNeeded()
        tv.setContentOffset(CGPoint(x: 0, y: -tv.contentInset.top), animated: false)
    }
    snap()

    anchorStartedAt = Date()
    anchorDeadline = anchorStartedAt!.addingTimeInterval(0.3)  // hard ceiling
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

Wiring (replacing the existing `scrollIfNeeded` block):
```swift
let scrollIfNeeded: () -> Void = { [weak tv, weak coord] in
    guard needsScroll, let tv = tv, let coord = coord else { return }
    coord.beginAnchoredScrollToBottom(in: tv)
}
```

The rest of `updateUIView` is unchanged (the animated path and the non-animated path both call `scrollIfNeeded`).

### 3.2 Why KVO over the two alternatives

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| **KVO contentSize** (chosen) | closed-loop — catches every contentSize change UIKit triggers; auto-stops on stable | KVO on `UIScrollView.contentSize` is not a fully-documented public contract; the pattern is widely used in real iOS chat apps | reliable enough for b1 |
| Custom `UITableView` subclass overriding `setContentSize:` | most reliable, doesn't depend on KVO behavior | touches the `UITableView(frame:style:)` init path in `makeUIView`; spreads into cell registration; heavy-handed for one fix | **deferred to Level 2** — this is the foundation for the rotated-table replacement |
| CADisplayLink for N frames | simple, frame-driven | wasted work if it settles in 1 frame; may miss late shifts after the N-frame window; no natural stop condition | rejected |

### 3.3 Stop conditions (3 overlapping mechanisms)

1. ContentSize stable for 2 consecutive KVO ticks (delta < 0.5pt) → `reason=stable`.
2. Hard 300ms deadline from start → `reason=deadline`.
3. User scrolls up (`offset > -inset.top + 120`) → `reason=user-scrolled-up`.

When `beginAnchoredScrollToBottom` is called again under rapid-send, the very first thing it does is call `cancelAnchor(reason: "superseded")` → preventing two windows from overlapping concurrently.

### 3.4 Threshold rationale

- **300ms hard ceiling**: PR #103's verification logs showed late shifts ending within 2 runloop ticks (~33ms at 60Hz) after apply-completion. 300ms is a 10× margin, plenty for slow Catalyst frames and async image-load reflow if needed.
- **120pt at-bottom threshold**: matches `scrollViewDidScroll`'s `current==true → next = offset < 120` (line 932) — consistent with the existing `isAtBottom` semantics.
- **0.5pt delta threshold**: pixel-level noise floor; below the threshold of human visibility; prevents KVO loops when `contentSize` jitters by 0.01pt.
- **2 stable ticks**: 1 tick may be a pause between two layout passes; 2 ticks = genuinely settled.

---

## 4. Acceptance Criteria

### 4.1 Quantitative measurement (from NSLog with `kAnchorLog = true`)

| AC | Criterion |
|---|---|
| **AC1** | After the `[anchor] end` line, reading `tv.contentOffset.y` via a probe should equal `-contentInset.top` ± 0.5pt. (One could add an extra log line after `end` to dump the final value.) |
| **AC2** | Every `[anchor] end` has `duration ≤ 300ms`. |
| **AC3** | Every `[anchor] kvo` line whose `cs.h` changes by ≥ 0.5pt must show `offset = -inset.top` (i.e., the snap ran inside the same tick). |
| **AC4** | Under rapid-send: the log sequence for two consecutive sends must follow the pattern `[anchor] start ... [anchor] end reason=superseded ... [anchor] start ...` — there must NOT be two `[anchor] start` lines without an `[anchor] end` in between. |

### 4.2 UX evaluation (manual scenarios)

Run on **iOS simulator** and **Mac Catalyst**:

| # | Scenario | Pass criteria | Type |
|---|---|---|---|
| S1 | Type "hello" → Return while at bottom | Bubble appears at bottom with NO visible jump on server confirm | golden — primary #104 case |
| S2 | Rapid send 10× short text (Return-Return-…) | All bubbles in tap order, no chaos, no "re-arrange chaotically" | golden — #104 worst case |
| S3 | Send a photo + caption (from photo picker) | Pending bubble has thumbnail (from b1 data parity); server confirm = NO resize | golden — b1 data parity |
| S4 | Reply to a message then Send | Pending bubble is text-only; server confirm adds quote-preview → small reflow expected (known limitation, out of scope b1) | regression — verify it's not worse than today |
| S5 | Scrolled up mid-list, an inbound message arrives from another user | Does NOT yank to bottom (anchor doesn't hijack because atBottom == false) | regression — invariant from #103 test plan |
| S6 | Send → back out immediately → re-enter | Pending bubble persists, then server-confirmed swap is smooth | regression — invariant 7 from optimistic-send-pipeline |
| S7 | Failed send → tap Retry | Scrolls to bottom correctly | regression — #103 test plan |
| S8 | On Mac Catalyst, send via Return AND via Send-arrow click | Both paths smooth | regression — #101 untouched |

### 4.3 Compile gate

- `xcodebuild` for `GitchatIOS local` scheme — iOS Simulator destination → **BUILD SUCCEEDED**.
- `xcodebuild` for `GitchatIOS local` scheme — Mac Catalyst destination → **BUILD SUCCEEDED**.
- No new warnings introduced relative to the `main` baseline.

---

## 5. Out of Scope

| Item | Reason | Tracked where |
|---|---|---|
| Reply-preview parity (snapshot `ReplyPreview` into `PendingMessage`) | Touches Codable schema → requires `outbox-pending.json` migration on user devices; risk exceeds the value for a single jank fix | v1.1 follow-up issue (not yet filed) |
| Replace rotated UITableView (issue's direction #4) | Multi-week refactor; touches all gesture/menu/sticky-avatar code | Companion spec [`2026-05-04-chat-list-anchored-collection-design.md`](2026-05-04-chat-list-anchored-collection-design.md) |
| Bubble lift animation from composer (iMessage parity) | Polish layer; needs its own design pass | Level 3 — not yet filed |
| Pre-sized cells with blurhash (eliminate self-sizing finalize) | Depends on Level 2 + attachment pipeline | Level 3 |
| `idb` automation for rapid-send | Optional (Layer 3.5 in the test plan) — will attempt but defer if env isn't ready | Plan task |

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| KVO `contentSize` doesn't fire for some internal UIKit corner case | Low | Bubble jank remains in that corner | Hard deadline + `cancelAnchor` ensure no observer leak; fallback behavior = same as today after the ceiling |
| `mappedAttachments` with `url == ""` causes a blank UI render | Medium | Pending bubble missing the expected thumbnail | The implementation plan has a dedicated task to probe rendering with empty url; fix at the renderer if needed |
| Anchor hijacks legitimate user scroll (S5) | Low | Annoying — yanks down when it shouldn't | At-bottom guard (`offset < -inset.top + 120`); explicit S5 test |
| Removed instrumentation (`kAnchorLog`) is forgotten before merge | Low | Console log noise in production | Reviewer checklist + grep gate in PR description |

---

## 7. Files changed

| File | Change | Estimated lines |
|---|---|---|
| `GitchatIOS/Core/OutboxStore.swift` | Expand `toMessage` | ~15 lines (mappedAttachments + 2 fields in the Message init) |
| `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` | Replace the `scrollIfNeeded` block; add `beginAnchoredScrollToBottom` + `cancelAnchor` + 4 stored properties on the Coordinator | -15 / +60 lines |
| `docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md` | NEW (this file) | ~300 lines |
| `docs/superpowers/specs/2026-05-04-chat-list-anchored-collection-design.md` | NEW (companion) | ~250 lines |
| `docs/superpowers/plans/2026-05-04-chat-send-jank-fix-implementation.md` | NEW (will be created via the writing-plans skill) | ~150 lines |

NO new/renamed Swift files → NO `xcodegen generate` needed.

---

## 8. References

- Issue: [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104)
- Just-merged PR: [#103](https://github.com/GitchatSH/gitchat-ios-native/pull/103)
- Original issue: [#102](https://github.com/GitchatSH/gitchat-ios-native/issues/102)
- Architecture (must read before touching the send path): `docs/architecture/optimistic-send-pipeline.md`
- Companion exploration: `2026-05-04-chat-list-anchored-collection-design.md`

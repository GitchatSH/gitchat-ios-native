# Chat rework — implementation plan

Companion to `docs/superpowers/specs/2026-04-23-chat-rework-design.md`.

All phases live on a single branch `feat/chat-rework`. One PR opens
when every phase is complete. Each phase is one (or a small cluster
of) commits in the order below.

Commits follow `feat(ios):` / `refactor(ios):` / `chore:` per CLAUDE.md,
always with the `Co-Authored-By: Claude Opus 4.7 (1M context)` trailer.

Every phase ends with the same canonical verification block:

- Build succeeds (`xcodegen generate && xcodebuild ... build` — **only
  when Xcode is closed**, else the user builds from Xcode).
- App launches; open a DM and a group; send a text; send an image;
  scroll up past pagination boundary; long-press a bubble; reply; edit;
  unsend; react; pin; unmute/mute; swipe-to-close.
- Repeat on Mac Catalyst target.
- No new `@State` on `ChatDetailView` beyond what the phase explicitly
  adds.

---

## Phase 0 — Spec + plan

**Commit:** `docs(chat): rework spec + phased plan`
**Files added:**
- `docs/superpowers/specs/2026-04-23-chat-rework-design.md`
- `docs/superpowers/plans/2026-04-23-chat-rework-plan.md`

Already landed on `feat/chat-rework` as commit `4226e1c`. Revised in a
follow-up commit after scoping discussion (Phase 1 approach changed).

---

## Phase 1 — Image cache (in-place improvements)

**Priority fix:** A (scroll jank from images).

**Revised approach:** after reading `ImageCache.swift` and
`CachedAsyncImage.swift`, the existing pipeline already has in-memory +
disk cache, off-main ImageIO downsampling, and inflight dedup. Kingfisher
would be a dependency for marginal gain. Instead, fix the three real
gaps: sync disk read on main, unbounded memory dict, no prefetch.

**Steps:**

1. `GitchatIOS/Core/UI/ImageCache.swift`:
   - Replace `private var storage: [String: UIImage]` with a
     `NSCache<NSString, UIImage>` wrapped in `ImageMemoryCache`. Set
     `totalCostLimit = 50 * 1024 * 1024`. Compute cost per insert as
     `Int(image.size.width * image.size.height * image.scale * image.scale * 4)`.
     Drop the `storageLock` — `NSCache` is thread-safe.
   - Add `warmFromDisk(_ url: URL, maxPixelSize: CGFloat?) async -> UIImage?`
     that runs `Data(contentsOf:)` on `Self.diskQueue` via
     `withCheckedContinuation`, decodes, caches, returns.
   - Keep `image(for:)` returning only the in-memory hit (make it
     pure sync lookup — no disk side effect).
   - Rename the existing method that synchronously touches disk to
     `imageSync(for:)` and mark it as `@available(*, deprecated)` so
     the compiler flags any remaining caller. Fix the one internal
     caller by routing through `warmFromDisk` async.
   - Add `prefetch(urls: [URL], maxPixelSize: CGFloat?)` that fires
     detached `Task`s through the existing inflight dedup.
   - Add `cancelPrefetch(urls: [URL])` that cancels the inflight
     `Task`s whose URLs are in the set.
2. `GitchatIOS/Core/UI/CachedAsyncImage.swift`:
   - `init`: keep the sync in-memory fast path via
     `ImageCache.shared.image(for:)`. Drop the sync disk fallback.
   - `load()`: first try in-memory, then `await warmFromDisk`, then
     `await load` (network). This moves the disk read off main but
     keeps the perceived-instant feel via the sync in-memory path.
3. `GitchatIOS/Features/Conversations/ChatDetail/ChatCollectionView.swift`:
   - Conform `Coordinator` to `UICollectionViewDataSourcePrefetching`.
     Assign `cv.prefetchDataSource = coordinator` in `makeUIView`.
   - `prefetchItemsAt(indexPaths:)`: pull the `Message` for each index
     path; extract `attachments?.map(\.url)` and `attachment_url` plus
     `sender_avatar`; collect remote URLs; call
     `ImageCache.shared.prefetch(urls:, maxPixelSize: 800)`.
   - `cancelPrefetchingForItemsAt(indexPaths:)`: collect the same URLs
     and call `ImageCache.shared.cancelPrefetch(urls:)`.
4. No xcodegen change needed (no new files, no package add).

**Verification (this phase):**
- Scroll a 300+-image conversation twice: second scroll shows every
  tile instantly from disk cache (warmFromDisk prefetched earlier).
- Kill-and-relaunch the app, open same conversation, scroll up and
  down once: every previously seen image appears within one frame
  (in-memory) or after the first frame (async disk warm).
- Instruments > Time Profiler during scroll: no `Data(contentsOf:)`
  stacks on the main thread.
- After a long session memory use stays below a bounded ceiling
  (watch memory graph in Xcode; `NSCache` evicts under pressure).

---

## Phase 2 — Composer + keyboard

**On branch:** `feat/chat-composer-keyboard`
**Priority fix:** B (composer snap).

**Steps:**

1. Add `GitchatIOS/Features/Conversations/ChatDetail/KeyboardTimedObserver.swift`:
   ```swift
   @MainActor
   final class KeyboardTimedObserver: ObservableObject {
     @Published private(set) var frame: CGRect = .zero
     @Published private(set) var lastChange: KeyboardChange = .zero
     // observes keyboardWillChangeFrameNotification; extracts frame,
     // duration, curve raw value; publishes atomically.
   }

   struct KeyboardChange {
     var frame: CGRect
     var duration: TimeInterval
     var curveRawValue: Int  // to build UIView.AnimationOptions
     static let zero = KeyboardChange(frame: .zero, duration: 0.25, curveRawValue: 7)
   }
   ```
2. Add `ChatDetail/Composer/ChatComposer.swift`:
   - Owns: draft binding, reply/edit state binding, mention suggestion
     binding, photo picker binding, send action closure.
   - Listens to `KeyboardTimedObserver`; when `frame` changes, drives a
     CALayer-level translation of its host via `UIViewRepresentable` so
     that the animation runs on the same `CADisplayLink` as the
     keyboard. Prefer `UIView.animate(withDuration: change.duration,
     delay: 0, options: [.init(rawValue: UInt(change.curveRawValue << 16))], animations: {...})`.
   - Exposes `@Published var composerHeight: CGFloat` for the
     collection view's bottom inset.
3. Extract from `ChatDetailView.swift`:
   - `composer`, `composerTextField`, `replyEditBar`,
     `mentionSuggestionList`, `clipboardChip(for:)`, mention
     helpers (`currentMentionToken`, `insertMention`) — move into
     `ChatComposer` and small sibling views:
     - `Composer/ComposerTextField.swift`
     - `Composer/ReplyEditBar.swift`
     - `Composer/MentionSuggestionRow.swift`
     - `Composer/ClipboardChip.swift`
4. Remove `KeyboardObserver` usage from `ChatDetailView.body`. Remove
   the outer `.padding(.bottom, keyboard.height - safeAreaBottom)` —
   the composer now sits in a `ZStack` bottom-aligned and animates
   itself; the collection view's `contentInset.bottom` tracks
   `composerHeight + keyboardInset`.
5. Verify Catalyst `onSubmit` → send flow still works
   (`#if targetEnvironment(macCatalyst)` branch moves with the
   text field).

**Verification:**
- Tap composer: composer tracks keyboard at every frame (slow-mo
  screen recording — visually inspect for any stutter).
- Change Accessibility → Motion → Reduce Motion: animation still
  in sync.
- Rotate iPad mid-conversation with keyboard up: composer lands at
  correct new offset without drift.
- `ChatDetailView.swift` LOC drops meaningfully (target: ~250 LOC
  removed).

---

## Phase 3 — Split god-view

**On branch:** `feat/chat-godview-split`
**Priority fix:** G (maintainability; also unblocks Phases 4+).

Purely structural. Zero user-visible change.

**Steps:**

1. Extract `messageActions(for:)` (the current `contextMenu` body)
   into `ChatDetail/MessageMenu/MessageMenuActions.swift` as a
   `MessageMenuActionList` view. It still renders as an iOS
   `contextMenu` content for now — Phase 4 replaces the host.
2. Extract `messageRow(for:at:)` into
   `ChatDetail/MessageRowBuilder.swift` — a small `struct` holding
   the closures currently captured by the closure literal.
3. Extract `chatToolbar`, `jumpToBottomButton`, `blockedBanner`,
   `reportSheet` into `ChatDetail/ChatScreenPieces/` as focused
   `View` structs.
4. Move `imageAttachmentURLs`, `copyImageToClipboard`, `quickReact`,
   `jumpToReply` into an extension on `ChatViewModel` (they're pure
   actions, not view state).
5. `ChatDetailView.body` ends up composing: `ChatBackground`,
   `MessagesListHost` (new tiny wrapper for skeleton-or-collection),
   `ChatComposer` (Phase 2), overlays. Target ≤ 350 LOC.

**Verification:**
- Feature parity: run the canonical checklist end-to-end; nothing
  differs user-visible.
- `xcodegen generate`; build iOS + Catalyst.
- `wc -l GitchatIOS/Features/Conversations/ChatDetailView.swift` ≤ 350.

---

## Phase 4 — Long-press menu preview

**On branch:** `feat/chat-menu-preview`
**Priority fix:** D (context-menu UX).

**Steps:**

1. Add `ChatDetail/MessageMenu/MessageMenuHost.swift`: a
   full-screen overlay `View` taking `menuTarget: MessageMenuTarget?`.
2. Add `ChatDetail/MessageMenu/MessageMenuPreview.swift`: the
   snapshot-based preview. Builds a `UIImage` via `cell.snapshotView(afterScreenUpdates: false)`
   (wrapped in a `UIViewRepresentable`), positions it at the original
   frame, then springs to a target frame near vertical center.
3. Add `ChatDetail/MessageMenu/ReactionPickerBar.swift`: a horizontal
   row of 8 emojis + a chevron that swaps the bar into a grid (reuse
   `EmojiPickerSheet`'s emoji list). Tap → `onReact(emoji)`; chevron
   → expands inline.
4. Replace `.contextMenu { ... }` wrapping on `bubbleContent` in
   `MessageBubble` with a `LongPressGesture(minimumDuration: 0.28)`
   that reports the tapped cell's global frame back to
   `ChatCollectionView.Coordinator`, which surfaces it via a new
   closure `onCellLongPressed(Message, CGRect)` → the view sets
   `menuTarget`.
5. Catalyst: bind `UIContextMenuInteraction` on the cell's content
   view; its delegate calls the same closure.
6. Overlay dismiss: tap background, drag preview down > 80pt,
   or any action tap.
7. Behind a `UserDefaults` dev flag `chat.menuPreview.enabled`
   defaulting to `true`. Flag is removed in Phase 5 PR description
   once confirmed stable in TF build.

**Verification:**
- All current menu actions still reachable; each executes identical
  behaviour.
- Reaction picker "more" expansion opens in ≤ 100ms.
- Preview snapshot keeps image content readable (no black square).
- VoiceOver: entering overlay focuses the preview, then cycles
  actions.
- Catalyst: right-click opens overlay; Esc dismisses.

---

## Phase 5 — Swipe-to-reply + reply bubble polish

**On branch:** `feat/chat-swipe-reply`
**Priority fix:** E.

**Steps:**

1. Add `ChatDetail/SwipeReplyModifier.swift`:
   ```swift
   struct SwipeReplyModifier: ViewModifier {
     let isMe: Bool
     let onTrigger: () -> Void
     @State private var offsetX: CGFloat = 0
     // DragGesture minimum 12pt horizontal before engaging
     // arrow icon fades in via opacity bound to |offsetX|/60
   }
   ```
2. Apply the modifier inside `MessageBubble`'s root (so the drag is
   scoped to the bubble, not the seen-by row below).
3. Extract reply-preview subview into
   `ChatDetail/ReplyBubble.swift`:
   - Thin colored leading bar (sender-specific tint via `ChatTheme`
     later; for now `Color.accentColor`).
   - Sender name (caption2, semibold, tinted).
   - One-line body truncated with `.lineLimit(1)`.
   - Attachment thumbnail 32×32 if reply was an image — uses
     `CachedImage` (Phase 1).
4. Remove current inline `replyPreview(reply)` function from
   `MessageBubble`.
5. On trigger: `Haptics.selection()`, set `vm.replyingTo = msg`,
   focus composer.

**Verification:**
- Swipe right on incoming message: bubble slides, arrow fades in,
  release past threshold → reply bar shows + keyboard focuses.
- Swipe left on outgoing message: same behaviour, mirrored.
- Vertical fast-scroll does not accidentally trigger reply.
- Reply inline preview shows attachment thumb when replying to
  an image-only message.

---

## Phase 6 — Date section headers

**On branch:** `feat/chat-date-headers`
**Priority fix:** polish (C).

**Steps:**

1. Add `ChatDetail/ChatSectioning.swift`:
   - `enum ChatRow { case message(Message); case dateHeader(Date, id: String) }`
   - `static func interleave(_ messages: [Message]) -> [ChatRow]`
     emitting a header whenever adjacent messages cross a calendar-day
     boundary in `Calendar.current` (user's local TZ).
2. Update `ChatCollectionView`:
   - Diffable data source item identifier becomes `String` still
     (prefix `"date-"` for headers).
   - Cell provider switches on prefix; header cell uses a pill label.
   - `reconfigureItems` sweeps filter out `date-*` ids.
3. Update `messageRow(for:at:)` to read from the interleaved list.

**Verification:**
- Conversation spanning 3+ days shows "Today" / "Yesterday" /
  "12 Apr 2026" pills at boundaries.
- Pagination (load older) produces correct headers for the older
  range.
- TZ change mid-session (e.g., airplane mode) doesn't duplicate
  headers.

---

## Phase 7 — Attachments grid + upload progress

**On branch:** `feat/chat-attachments-grid`
**Priority fix:** F.

**Steps:**

1. Add `ChatDetail/AttachmentsGrid.swift`:
   - 1/2/3/4+ layouts as specified in spec §6.8.
   - Each tile is `CachedImage` + optional `AttachmentProgressOverlay`.
   - Tap forwards the url to `onAttachmentTap`.
2. Add `ChatDetail/AttachmentProgressOverlay.swift`: circular
   determinate ring backed by a `Double` binding; fades on
   completion.
3. Update `ChatViewModel`:
   - `@Published var uploadProgress: [String: [Double]] = [:]`
     keyed by `localID`, value is per-attachment fraction.
   - `uploadAndSendMany`: replace inline `APIClient.uploadAttachment`
     call with a variant that accepts
     `progress: (_ index: Int, _ fraction: Double) -> Void`.
4. Update `Core/Networking/APIClient+Attachments.swift`
   (create if necessary) to wire progress via
   `URLSessionTaskDelegate.urlSession(_:task:didSendBodyData:...)`.
5. In `MessageBubble`, replace the current manual attachment
   rendering with `AttachmentsGrid(attachments:, progress:)`.

**Verification:**
- Send 1/2/3/4/6 images: grid matches reference screenshots
  (iMessage layout) + "+N" overlay on the 6-image case.
- Ring progress increases smoothly to 100% on each tile
  independently.
- Tapping a tile mid-upload does not crash (the tap is ignored
  when progress < 1).
- Server echo replaces the optimistic row; grid does not
  reshuffle.

---

## Phase 8 — Animations pass

**On branch:** `feat/chat-animations`
**Priority fix:** C.

**Steps:**

1. Add `ChatDetail/ChatAnimations.swift`:
   - `bubbleAppear`, `reactionPop`, `pulseHighlight` transitions
     and animations.
2. Apply `bubbleAppear` to the `UIHostingConfiguration` content
   inside the cell builder (only when
   `!MessageBubble.seenIds.contains(id)` as today).
3. Apply `reactionPop` to reaction chip insertion; use
   `.symbolEffect(.bounce)` on the count label on increment.
4. Replace the ad-hoc typing-dots animation in
   `TypingIndicatorRow` with a `TimelineView`-driven phased
   opacity so it keeps animating while the diffable apply is
   running.
5. Scroll-to-bottom pill: match the `.buttonStyle(.glass)` on
   iOS 26+, align transition with `reactionPop`.

**Verification:**
- Bubble appearances feel purposeful, not abrupt; first-load
  pagination does NOT animate (seenIds prevents it).
- Double-tap heart: chip pops, count bumps with bounce.
- Typing dots stay animating while messages arrive.

---

## Phase 9 — Theme consolidation

**On branch:** `feat/chat-theme`
**Priority fix:** polish / G.

**Steps:**

1. Add `ChatDetail/ChatTheme.swift`:
   ```swift
   struct ChatTheme {
     let bubbleIncoming: Color
     let bubbleOutgoing: Color
     let bubbleIncomingText: Color
     let bubbleOutgoingText: Color
     let replyAccent: Color
     let dateHeaderBg: Color
     let menuBarBg: Color
     // ...
     static let `default` = ChatTheme(/* current values */)
   }
   ```
2. Route through the environment:
   `.environment(\.chatTheme, .default)` at `ChatDetailView` root.
3. Replace hard-coded `Color("AccentColor")`,
   `Color(.secondarySystemBackground)`, `Color(.tertiarySystemFill)`
   etc. used inside chat components with theme lookups.
4. No dynamic theming exposed yet — just the abstraction.

**Verification:**
- Visual diff vs pre-theme screenshot is zero on both light and
  dark mode.
- Grep shows zero hard-coded chat colors left inside
  `Features/Conversations/ChatDetail/`.

---

## Cross-cutting conventions (every phase)

- After adding any Swift file: `xcodegen generate`.
- Commit message: `feat(ios): <phase subject>` or
  `refactor(ios): <phase subject>`, plus the co-author trailer.
- Do NOT commit build products, DerivedData, `.xcworkspace`, etc.
- Do NOT add `Fixes #N` / `Closes #N`. Use `refs #N` if a
  GitHub issue is linked; reviewer closes manually.
- Each PR body includes: What / Why / Refs / Not-in-this-PR /
  Test plan. English only.
- After merge: comment on any referenced issues with
  delivered / not delivered / caveats.
- If a phase surfaces unexpected scope: stop, update the spec in a
  follow-up doc PR before continuing.

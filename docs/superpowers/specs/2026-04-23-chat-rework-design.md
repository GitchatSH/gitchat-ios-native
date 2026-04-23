# Chat rework — design spec

Date: 2026-04-23
Status: Draft / pending review
Branch: `feat/chat-rework-spec` (this doc + plan), then one branch per phase.

## 1. Goals

Rework the conversation screen (`Features/Conversations/ChatDetail/`) to land on par
with iMessage / Telegram for perceived performance and interaction polish, while
keeping 100% of Gitchat-specific features. The concrete user-visible problems we
are solving, in priority order:

1. **(A)** Scroll jank, especially with messages containing images — root causes
   are: no disk cache for remote images, decode on main thread, estimated-height
   cells that resize after first render, image views without intrinsic size until
   the async load resolves.
2. **(B)** Composer does not snap to the keyboard. Current code observes
   keyboard frame via `KeyboardObserver` and applies `.padding(.bottom, …)` that
   animates with SwiftUI's default curve — which is not the keyboard's curve, so
   the composer lags the keyboard by a few frames on show/hide.
3. **(C)** No purposeful animation on key interactions: bubble appear, reaction
   pop, typing dots, reply-pulse are either missing or ad-hoc.
4. **(D)** Long-press menu uses the default iOS `.contextMenu`, which is
   functional but feels generic — no message preview "flies up", no bespoke
   reaction picker, reactions currently crammed into `ControlGroup` pairs.
5. **(E)** Reply UX is keyboard-only today (tap the action in the menu). No
   swipe-to-reply. Reply preview rendering in the bubble is plain.
6. **(F)** Multi-image send renders tiled one-image-per-row; no iMessage-style
   grid (1 / 2 / 3 / 4+ layouts); no upload progress percentage.

## 2. Non-goals

- Voice messages (exyte has this; parked for later).
- Giphy picker (parked; would pull Giphy SDK).
- `comments` chat type or list-above-input mode — Gitchat is always
  conversation-style, newest at bottom.
- Replacing the UICollectionView foundation. The existing
  `ChatCollectionView` (compositional layout + diffable data source +
  `UIHostingConfiguration` cells) is sound and matches what
  Telegram / iMessage do. We keep it.
- Swapping `Message` / `Conversation` models. All BE contracts stay.
- Introducing new background / sync infrastructure (the existing
  `SocketClient` + `MessageCache` + optimistic-send pattern stays).

## 3. What we keep from the current app

Every feature listed here continues to work after the rework:

- Pin / unpin message, `PinnedMessagesSheet`, pin badge on bubble.
- Read receipts (`otherReadAt` for DM, `readCursors` per-login for group).
- Seen-by avatar row under the last message each participant has read
  (group chats).
- Unsend / edit / delete own message; report + auto-block from others.
- `BlockStore`-filtered visible message list.
- `@login` mention detection + horizontal suggestion chips + insert.
- Typing indicator row.
- Mac Catalyst drag-and-drop image import + drop-confirm preview sheet.
- Clipboard-image chip above composer.
- Mute / unmute conversation.
- Deep-link `gitchat://user/<login>` from bubble text.
- Forward message sheet.
- Jump-to-bottom button with glass style.
- Optimistic local-id send + swap-on-server-echo pattern.
- Message cache (`MessageCache`), cursor pagination (`loadMoreIfNeeded`).

## 4. What we port from exyte/chat

Source: `_ignore/Chat/Sources/ExyteChat/**` (MIT license, safe to port). We
port patterns and selected code — not the whole library, and not as a
SwiftPM dependency. Each item below names the exyte file(s) it derives from.

| Area | From (exyte) | Gitchat target |
|---|---|---|
| a. Message menu with preview "fly-up" + bespoke reaction picker | `Views/MessageView/MessageMenu*.swift`, `Views/ChatView/ChatView.swift` menu host | `Features/Conversations/ChatDetail/MessageMenu/*` |
| b. Swipe-to-reply gesture | `Views/MessageView/MessageView.swift` swipe offset handling | `Features/Conversations/ChatDetail/SwipeReplyModifier.swift` |
| c. Reply inline preview (Quote mode look) | `Views/MessageView/ReplyBubbleView.swift` | Update `MessageBubble.replyPreview` |
| d. Date section headers | `Views/ChatView/*` section logic | `Features/Conversations/ChatDetail/ChatSectioning.swift` |
| e. Scroll APIs — animated `scrollTo(id:)`, `contentOffset` binding, refined "scroll to bottom" pill | `Views/ChatView/ChatView.swift` | Extend `ChatCollectionView` coordinator |
| f. Upload progress (%) per attachment | `Model/Attachment.swift` `UploadStatus`, `Views/Attachments/*` | Extend `MessageAttachment`-local optimistic with `UploadProgress` + UI overlay |
| g. Multi-image iMessage-style grid (1/2/3/4+) | `Views/Attachments/AttachmentsGrid.swift` (or equivalent) | `Features/Conversations/ChatDetail/AttachmentsGrid.swift` |
| h. Theme struct | `Theme/ChatTheme.swift` | `Features/Conversations/ChatDetail/ChatTheme.swift` |
| i. Bubble-appear / reaction-pop / typing-dots animations | `Views/MessageView/*` transition code | Shared `ChatAnimations.swift` |
| Keyboard-curve-matched animation | `Managers/KeyboardState.swift` extended | New `KeyboardTimedObserver` (see §6.2) |

## 5. What we deliberately skip from exyte

- Kingfisher-driven `AsyncImageView` — we're swapping our own `ImageCache` for
  Kingfisher **app-wide** (see §6.3), and reusing a single `KFImage`-based view
  instead of importing exyte's.
- Giphy, voice, recording views — out of scope.
- Their `MessagesView` UITableView wrapper — we already have
  `ChatCollectionView` doing the equivalent job.
- Their `ChatTheme.images` set (background images for portrait/landscape etc.)
  — our `ChatBackground` already does this; we port only the color tokens.

## 6. Target architecture

### 6.1 Folder / file layout after rework

```
GitchatIOS/Features/Conversations/ChatDetail/
  ChatDetailView.swift                 # thin shell: navigation + sheets + composer focus
  ChatViewModel.swift                  # unchanged API, internals unchanged
  ChatCollectionView.swift             # existing; gains date-header, progress hooks
  ChatSectioning.swift                 # NEW — date-boundary helpers
  ChatTheme.swift                      # NEW — color tokens (ported + consolidated)
  ChatAnimations.swift                 # NEW — shared animation curves / transitions
  KeyboardTimedObserver.swift          # NEW — replaces KeyboardObserver
  Composer/
    ChatComposer.swift                 # NEW — extracted from ChatDetailView
    ComposerTextField.swift            # NEW — iOS + Catalyst branches
    ReplyEditBar.swift                 # moved out of ChatDetailView
    MentionSuggestionRow.swift         # moved out of ChatDetailView
    ClipboardChip.swift                # moved out of ChatDetailView
  MessageMenu/
    MessageMenuHost.swift              # NEW — overlay controller
    MessageMenuPreview.swift           # NEW — snapshot + fly-up animation
    ReactionPickerBar.swift            # NEW — bespoke picker replacing ControlGroup
    MessageMenuActions.swift           # NEW — action list
  MessageBubble.swift                  # unchanged responsibilities, drops contextMenu wiring
  ReplyBubble.swift                    # NEW — extracted reply preview (polished)
  SwipeReplyModifier.swift             # NEW — gesture modifier applied to each cell
  AttachmentsGrid.swift                # NEW — 1/2/3/4+ image layouts
  AttachmentProgressOverlay.swift      # NEW — per-tile upload progress UI
  SystemMessageRow.swift               # existing
  TypingIndicatorRow.swift             # existing; gains canonical animation
  ...existing sheets unchanged...
```

Goal: `ChatDetailView.swift` drops from ~1270 LOC to **< 350 LOC** (toolbar,
sheets routing, state binding only — no view-building hot paths). Every
file above stays ≤ ~400 LOC.

### 6.2 Composer + keyboard

The root cause of "not snapping" is that our padding animates with SwiftUI's
default curve, not the keyboard's curve.

Replace `KeyboardObserver` with `KeyboardTimedObserver` that exposes:

```swift
struct KeyboardChange {
  let frame: CGRect
  let duration: TimeInterval      // from UIKeyboardAnimationDurationUserInfoKey
  let curve: UIView.AnimationCurve // from UIKeyboardAnimationCurveUserInfoKey
}
```

The composer host listens and wraps state mutations in
`UIView.animate(withDuration: duration, delay: 0, options: [AnimationOptions(curve)], ...)`,
or for pure-SwiftUI state, in `withAnimation(.interpolatingSpring(duration: duration, bounce: 0))`
tuned to match. Because `UIView.animate` drives layout synchronously with
the keyboard's own animation, the composer tracks pixel-perfect.

We also move the composer out of `ChatDetailView`'s padding path entirely
and into a dedicated `ChatComposer` that owns its own height and offset.
This removes the current `.padding(.bottom, keyboard.height - safeAreaBottom)`
on the outer view (which was forcing the entire content stack to relayout on
every frame of the keyboard animation).

### 6.3 Image cache

Add Kingfisher as a SwiftPM dependency (`project.yml` → `packages:`) and
wrap it with a thin `CachedImage` view used both inside and outside chat:

```swift
struct CachedImage<P: View, F: View>: View {
  let url: URL?
  @ViewBuilder var placeholder: () -> P
  @ViewBuilder var failure: () -> F
  var body: some View { /* KFImage */ }
}
```

Then a sweep replaces every call site that currently uses
`ImageCache.shared.load(url)` + manual `Image(uiImage:)` (avatars, attachments,
link previews, seen-by avatars, ...). `ImageCache` itself is kept around for
code paths that need raw `UIImage` (e.g. "Copy image" in the message menu) —
those route through Kingfisher's retriever under the hood. This phase is a
standalone PR because it touches files outside `ChatDetail/`.

### 6.4 Message menu with preview

Long-press on a bubble:

1. `MessageMenuHost` overlay is presented fullscreen (no UIKit
   `.contextMenu`).
2. The bubble is snapshotted, the background dims + blurs with
   `.ultraThinMaterial`, the snapshot transitions to its source frame at
   first, then springs to a target frame (fly-up) centered near the middle
   of the screen.
3. A `ReactionPickerBar` appears above the bubble with 8 quick emojis +
   a "more" chevron that swaps the bar into the full grid (replacing
   `EmojiPickerSheet` for the in-menu path; the sheet stays for standalone
   reaction add from the reactors list).
4. A vertical `MessageMenuActionList` appears below, with the same actions
   currently shown in `.contextMenu` (Reply / Copy / Copy Image / Pin /
   Forward / Seen By / Edit / Unsend / Delete / Report).
5. Dismiss via tap outside, pan down on the preview, or on action selected.

Implementation notes:
- Use a single `@State private var menuTarget: MessageMenuTarget?` in
  `ChatDetailView` — `menuTarget != nil` drives the overlay.
- `MessageMenuTarget` carries `Message`, `CGRect` (global frame of the
  tapped cell), `isMe`, resolved avatar, etc.
- `ChatCollectionView` exposes a `LongPressGestureRecognizer` on each cell
  that fires `onMessageLongPressed(Message, CGRect)` up to SwiftUI.
- On Catalyst, bind to right-click (`UIContextMenuInteraction`) too so the
  same overlay opens.
- Accessibility: overlay traps VoiceOver focus; actions are real buttons.

### 6.5 Swipe-to-reply

`SwipeReplyModifier` is a `ViewModifier` applied inside each cell's
`UIHostingConfiguration`. It:
- Tracks a horizontal drag; clamps to one direction based on `isMe`
  (outgoing: drag left → reply, incoming: drag right → reply).
- Renders an arrow icon that fades in past ~20pt.
- On release past threshold (~60pt): `Haptics.selection()` + call
  `onSwipeReply(message)`, which sets `vm.replyingTo = msg` and focuses
  the composer.
- On release below threshold: spring back to 0.

The modifier does NOT trigger vertical scroll cancel — we use
`highPriorityGesture` only after a minimum horizontal translation so the
collection view's vertical pan still wins.

### 6.6 Reply inline preview polish

`ReplyBubble` replaces the inline `replyPreview(reply)` block in
`MessageBubble`. Visual: thin colored leading bar, sender name in caption
weight, one-line body truncated, attachment thumbnail if reply was an image.
Tap jumps + pulses the referenced message (unchanged behavior).

### 6.7 Date section headers

`ChatSectioning` computes day boundaries from `Message.created_at` and
emits synthetic `DateHeaderRowID` items at boundaries. Rendered via a
lightweight hosting cell with a pill background ("Today" / "Yesterday" /
"12 Apr 2026"). Section-boundary items are excluded from any
`reconfigureItems` sweep.

### 6.8 Multi-image grid

`AttachmentsGrid` takes `[MessageAttachment]` and renders:
- 1 → single tile, aspect-clamped at 240pt wide / max 320pt tall.
- 2 → two equal tiles side-by-side.
- 3 → one large left, two stacked right.
- 4+ → 2×2 grid, with "+N" overlay on the 4th tile when count > 4.

Tiles use `CachedImage` (Kingfisher) with a solid placeholder colour so
layout is stable before the image resolves. Each tile accepts an
`UploadProgress?` and renders `AttachmentProgressOverlay` (circular
determinate ring) when uploading. The overlay animates out on completion.

### 6.9 Upload progress plumbing

`ChatViewModel.uploadAndSendMany` currently kicks an `APIClient.uploadAttachment`
per image and awaits a flat URL. We extend the APIClient call site to accept
a progress closure, store a `[String: Double]` (localID → 0...1) on the VM,
and pass the slice into `AttachmentsGrid` via the cell builder. When the
send response comes back, the map entry is dropped.

BE: uses multipart upload; we wire `URLSessionUploadTask`'s
`URLSessionTaskDelegate.didSendBodyData` for per-task progress. If the
endpoint does not support `Content-Length` streaming the progress collapses
to indeterminate spinner (fallback).

### 6.10 Animations

Single `ChatAnimations.swift`:
- `.bubbleAppear`: `asymmetric(insertion: .scale(0.92).combined(with: .opacity), removal: .opacity)` with a gentle spring.
- `.reactionPop`: `.spring(response: 0.28, dampingFraction: 0.55)` on chip appear + `symbolEffect(.bounce)` on count-increment.
- `.typingDots`: timed phased opacity using `TimelineView`, not an explicit animation block.
- `.replyPulse`: keep existing two-stage, but move timing into
  `ChatAnimations.pulseHighlight`.

## 7. Phases / PR breakdown

Each phase is an independent branch + PR. Order is chosen so every
phase independently improves the app, and later phases compose on top of
the earlier ones.

| # | Branch | PR scope | Priority fixes |
|---|---|---|---|
| 0 | `feat/chat-rework-spec` | This spec + plan only | — |
| 1 | `feat/chat-image-cache` | Add Kingfisher, `CachedImage`, sweep call sites | A |
| 2 | `feat/chat-composer-keyboard` | Extract `Composer/*`, `KeyboardTimedObserver`, curve-matched animation | B |
| 3 | `feat/chat-godview-split` | Extract `MessageMenu/*`, `ReplyBubble`, `ReplyEditBar`, `MentionSuggestionRow`, `ClipboardChip` out of `ChatDetailView` (no UX change) | G (maintainability) |
| 4 | `feat/chat-menu-preview` | New long-press preview + reaction picker + action list | D |
| 5 | `feat/chat-swipe-reply` | `SwipeReplyModifier` + polished `ReplyBubble` render | E |
| 6 | `feat/chat-date-headers` | `ChatSectioning` + date-header cell | C (polish) |
| 7 | `feat/chat-attachments-grid` | `AttachmentsGrid` + `AttachmentProgressOverlay` + VM progress plumbing | F |
| 8 | `feat/chat-animations` | `ChatAnimations`, scroll-to-bottom polish, bubble-appear, reaction pop, typing dots | C |
| 9 | `feat/chat-theme` | Consolidate colors into `ChatTheme`, apply throughout chat | polish / G |

Each PR is reviewed and shipped before the next starts. No feature flag —
the rework is additive-or-isomorphic at every phase (nothing user-facing
breaks mid-flight).

## 8. Rollout & safety

- Incremental per-PR as above; `main` stays shippable after every merge.
- Each phase has its own Test Plan in its PR body (unit where
  applicable, but mostly device checklist: iOS 17, iOS 26, iPad, Mac
  Catalyst — CLAUDE.md requires both iOS and Catalyst verification for
  anything touching the chat view).
- Phase 4 (menu preview) is the highest-risk UX change; it will ship
  behind a `UserDefaults`-backed dev toggle for the first build and
  removed in the next build once confirmed.
- No BE changes except Phase 7 progress plumbing (no new endpoints;
  uses existing multipart upload).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Catalyst type-check ceiling on `ChatDetailView` gets worse before it gets better | Phase 3 (godview split) runs before any UX-heavy phase; verify Catalyst build after every phase |
| Kingfisher sweep leaves dead `ImageCache` call sites | Explicit grep in Phase 1 acceptance criteria; `ImageCache` becomes a thin wrapper if any non-UI caller remains |
| Menu preview overlay racing with SwiftUI sheet presentations | Menu is presented via a fullscreen-cover bound to `menuTarget`; only one modal layer active at a time |
| Swipe-to-reply cancelling vertical scroll on fast scroll-up | High-priority gesture only activates after ≥12pt horizontal translation; no `simultaneousGesture` |
| Upload progress confusing when retry | Local optimistic row keeps `localID`; retry replaces the entry; progress map rebinds |
| Kingfisher size + license | MIT; ~400KB; acceptable vs custom disk cache work |

## 10. Open questions

None blocking. If any surface during phase implementation, they'll be
resolved in that PR's description, not in this spec.

## 11. Success criteria

- Scrolling a 500-message conversation with mixed images feels **steady
  60 fps on iPhone 13 mini** (scroll Instruments, no frame drops > 1
  over a 10-second scroll).
- Tapping the composer to focus the keyboard: composer bottom edge is
  within 1pt of the keyboard's top edge at every frame of the
  keyboard animation (measured by `QuartzCore` display-link snapshot
  during review).
- Long-pressing a bubble opens the bespoke preview overlay in ≤ 120 ms
  and always presents reaction + action affordances.
- Swiping a bubble left/right (by sender side) slides and lands the
  message into the reply bar; composer auto-focuses.
- Sending 4 images shows a 2×2 grid during upload, per-tile
  circular-progress ring, and grid stays stable when server URLs arrive.
- `ChatDetailView.swift` is under 350 lines after Phase 3.

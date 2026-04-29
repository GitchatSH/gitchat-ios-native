# Telegram-style forwarded-message header — iOS

**Status:** Pending user review
**Author:** Ethan
**Date:** 2026-04-29
**Related:** [GitchatSH/gitchat-ios-native#73](https://github.com/GitchatSH/gitchat-ios-native/issues/73) (image attachments now forward — separate fix in `gitchat-webapp` PR #70)
**Scope:** iOS-only. No backend, schema, DTO, socket-protocol, or extension changes.

## Problem

Forwarded messages render with a literal `> Forwarded from @user` line of body
text instead of a styled header bubble. Reproduction in chat:

```
┌──────────────────────────┐
│ [card preview]           │
│                          │
│ > Forwarded from @user   │  ← plain text in body, ugly
│                  03:59 ✓ │
└──────────────────────────┘
```

The user wants Telegram's style:

```
┌──────────────────────────┐
│ ↪ Forwarded from @user   │  ← styled header at top
│ [card / image / text]    │
│                  03:59 ✓ │
└──────────────────────────┘
```

## Root cause (verified against current code)

The iOS app **already implements Telegram-style header rendering** —
`ChatMessageView.swift:493-504` draws an `arrowshape.turn.up.right.fill` icon
plus a bold caption2 "Forwarded from @login", and `ChatMessageView.swift:578`
adds a subtle border to the bubble overlay. It just never fires because of two
gaps:

1. **Format mismatch.** `ChatMessageText.parseForwarded`
   (`ChatMessageText.swift:23-35`) uses regex
   `^Forwarded from @<login>\n` (no `>`, single newline). The backend's
   `MessagesService.forwardMessage` emits
   `> Forwarded from @<login>\n\n<body>` (markdown blockquote, double
   newline). The regex never matches, so `parsed.forwardedFrom` is always
   `nil`, the styled header block is skipped, and the literal prefix is
   rendered as part of the message body.

2. **Bubble VStack order.** Even if the regex matched, the current bubble
   layout (`ChatMessageView.swift:480-504`) renders the attachment **before**
   the forwarded-from header:

   ```
   VStack {
     attachment        ← renders first
     senderName
     forwardedFrom     ← renders after attachment
     replyQuote
     bodyText
     ...
   }
   ```

   Telegram puts the header at the top of the bubble. With the current order
   the styled header (once it fires) would still be visually below the image.

## Goal

After this change, every forwarded message — past or future, image, image+
caption, text, or shared post — renders on iOS with the existing styled
"Forwarded from @login" header at the **top** of the bubble, and no literal
`> Forwarded from …` text appears anywhere in the body.

### Acceptance criteria

- [ ] AC1 — Image-only forward: bubble renders header at top, image below,
  no plain-text prefix in body.
- [ ] AC2 — Image-with-caption forward: bubble renders header at top, image
  below header, caption below image. No `>` prefix.
- [ ] AC3 — Text-only forward: bubble renders header at top, body text below.
  No `>` prefix.
- [ ] AC4 — Forwarded shared post (`@login` mention rendered as profile card):
  bubble renders header at top, card below, no duplicate prefix.
- [ ] AC5 — Existing forwards already in a conversation's history (stored
  with the legacy `> Forwarded from @user\n\n…` body) render with the new
  header on next read — no migration, no manual user action.
- [ ] AC6 — Non-forwarded messages are unaffected: layout and styling
  identical to current behavior.
- [ ] AC7 — Bubble overlay border (`ChatMessageView.swift:578`) fires only
  for forwarded bubbles, as it does today.
- [ ] AC8 — Group-chat incoming forward (rare): `showSenderName` (the
  forwarder's `@login`) renders **after** the attachment as it does today;
  the new forwarded-from header sits at the very top of the bubble, above
  both. Final order in this case: `forwardedHeader → attachment →
  senderName → body`. Not a perfect match for Telegram's group-forward
  ordering but visually clear and avoids touching the non-forwarded
  group-chat layout.

## Out of scope

- Backend / schema / DTO changes. The BE keeps emitting the existing prefix
  format so web and extension clients keep their markdown-blockquote
  rendering.
- Avatar in the header. Telegram shows an avatar circle next to the sender
  name; matching that requires a structured forward field (login + display
  name + avatar URL on the message DTO) and is deferred.
- Tap-to-source. Telegram lets you tap the header to jump to the original
  message; needs a stored `forwarded_from_message_id`. Deferred.
- Extension's separate forward bug (drops attachments entirely — see
  GitchatSH/gitchat-ios-native#73 BE comment thread). Different code path
  in `gitchat_extension/src/webviews/chat-handlers.ts`.
- Backfill / cleanup of legacy forward bodies. The flexible regex below
  retroactively renders them correctly without touching stored data.

## Design

Two iOS file changes. Roughly 5 lines each.

### 1. Flexibilize the forwarded-prefix regex

**File:** `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageText.swift`

Update `forwardedRegex` (line 92-98) to optionally accept the leading `>`
markdown-blockquote marker and one-or-more trailing newlines. The capture
group for the login is unchanged.

Current:

```swift
#"^Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n"#
```

Proposed:

```swift
#"^(?:>\s+)?Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n+"#
```

What this matches:
- `> Forwarded from @user\n\nbody` — current backend forward format ✓
- `Forwarded from @user\nbody` — original iOS-side expectation, future
  cleaner format ✓
- `> Forwarded from @user\nbody` — single-newline blockquote variant ✓

What this still rejects:
- `Forwarded from @user` with no trailing newline (no body to extract) — same
  as before
- `>>Forwarded from @user` (extra `>`) — would not match because we require
  one `>` followed by whitespace; acceptable

`parseForwarded` returns `(forwardedFrom, body)` where `body` is everything
after the matched prefix — the `\n+` consumes both the single-newline and
double-newline variants, so trailing blank lines never leak into the rendered
body.

### 2. Reorder bubble VStack so the header sits above the attachment

**File:** `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

Move the `if let from = parsed.forwardedFrom { … }` block (lines 493-504) so
it appears **before** the `if hasAttachment { attachmentContentUnclipped }`
block (lines 482-484) when `parsed.forwardedFrom != nil`.

To preserve current layout for non-forwarded messages with attachments
(image-on-top), the simplest approach: keep the structure but conditionally
hoist the header.

```swift
let bubble = VStack(alignment: .leading, spacing: 0) {
    if let from = parsed.forwardedFrom {
        forwardedHeader(from: from)        // extracted helper
    }
    if hasAttachment {
        attachmentContentUnclipped
    }
    if showSenderName { … }                 // unchanged
    if showInlineReply, let reply = … { … } // unchanged
    if hasText { … }                        // unchanged
    if let linkURL = … { … }                // unchanged
    if let reactions = … { … }              // unchanged
}
```

The duplicate-render concern: the original `if let from = parsed.forwardedFrom`
block at line 493 must be removed so the header isn't rendered twice. Extract
it into a small `@ViewBuilder` helper (`forwardedHeader(from:)`) on
`ChatMessageView` to keep the VStack readable and to keep all the styling
constants (icon, font, foreground style, padding) in one place.

The bubble overlay border (line 575-583) already keys off
`parsed.forwardedFrom != nil` — no change needed.

### Padding adjustments

When the forwarded header sits above the attachment, the attachment loses its
former top edge of the bubble. Cases:

- Header → attachment: header has `.padding(.top, 8)` and
  `.padding(.bottom, 4)` (unchanged). The attachment renders flush below the
  header at the bubble interior, which matches Telegram's tight stacking.
- Header → text (no attachment): existing padding is correct.
- Header → reply quote: the existing reply-quote `.padding(.top,
  parsed.forwardedFrom == nil ? 6 : 2)` already accounts for the header
  being present. Unchanged.

If the manual sim test reveals a visible padding bug (e.g., header touching
the image edge with no breathing room), tighten `.padding(.bottom, 4)` on the
header to taste. This is a polish loop, not an architecture decision.

## Components / data flow

No new data types. No new services. No new state. The flow is purely a
re-shape of how the existing `body` string is parsed and how the existing
`parsed.forwardedFrom` view branch is laid out.

```
Message.body  ─►  ChatMessageText.parseForwarded(_:)
                       │
                       ▼
                  (forwardedFrom: String?, body: String)
                       │
                       ▼
                  ChatMessageView bubble VStack
                       │
                       ├── forwardedHeader(from:)   when forwardedFrom != nil
                       ├── attachment               when hasAttachment
                       ├── senderName               when showSenderName
                       ├── replyQuote               when showInlineReply
                       └── body                     when hasText
```

`ChatMessageText.attributed(_:isMe:)` (the cached attributed-string builder)
is unaffected — it only ever sees the stripped `body`, never the prefix.

## Error handling

There is no failure mode introduced. The regex either matches (prefix
stripped, header shown) or doesn't (full body rendered as before — same as
today). No new I/O, no new server roundtrips, no new state to invalidate.

## Testing

iOS has no XCTest target (per `gitchat-ios-native/CLAUDE.md`). Verification is
`xcodebuild` compile + manual scenarios on the simulator.

### Compile gate

```bash
xcodebuild -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Must succeed. Specifically confirm both edited Swift files are still in
`project.pbxproj` (per CLAUDE.md guidance on xcodegen-managed projects).

### Manual scenarios on simulator

Run against the dev backend (which still emits the legacy
`> Forwarded from @user\n\n…` prefix).

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Forward an image-only message | Header at top of bubble (`↪ Forwarded from @login`), image below, no plain-text prefix anywhere. |
| 2 | Forward an image+caption message | Header at top, image, caption below. No `>`. |
| 3 | Forward a text-only message | Header at top, body text below. No `>`. |
| 4 | Forward a message containing an `@login` mention that renders as a profile card | Header at top, card embedded inline, no duplicate `> Forwarded from …` text under it. |
| 5 | Open an existing chat with forwards from before this change | Each legacy forward now renders with the new header. Body shows only the original content. |
| 6 | Send a regular non-forwarded message | Identical to current rendering. No border, no header. |
| 7 | Long-press a forwarded bubble → Forward again | The forward-of-a-forward path: BE will prefix again, producing `> Forwarded from @me\n\n> Forwarded from @original\n\n…`. The flexible regex strips one prefix; the second `> Forwarded from …` line stays in the body and renders as a quoted line. Acceptable / matches Telegram's "double-forward" rendering. |

### Regression watch

- Bubble corner radius / tail rendering: unchanged paths.
- Reactions row positioning at bubble bottom: unchanged paths.
- Reply-quote rendering inside forwarded bubbles: existing
  `.padding(.top, parsed.forwardedFrom == nil ? 6 : 2)` already accounts for
  the header.
- Catalyst layout: same SwiftUI tree applies; no Catalyst-specific code
  changed.

## Build sequence

1. Edit `ChatMessageText.swift` — flexibilize regex.
2. Edit `ChatMessageView.swift` — extract `forwardedHeader(from:)` helper,
   remove inline header from VStack, prepend it before attachment.
3. `xcodebuild build` — confirm clean compile.
4. Run on `iPhone 16` simulator + dev backend, run scenarios 1-7.
5. If any padding looks off, polish the header `.padding(.bottom, …)` value.
6. Commit on `feat/telegram-forward-header` (already created), open PR
   against `main`.

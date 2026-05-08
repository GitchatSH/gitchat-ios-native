# Compact message preview — push notification + chat list + noti tab

**Status:** Pending user review
**Author:** Ethan
**Date:** 2026-05-08
**Scope:** iOS push notification body, iOS in-app chat list, extension chat list, extension Noti tab. No webapp UI (web frontend lives inside extension/backend bundle). No chat-bubble change (covered separately by `2026-04-29-telegram-style-forward-header.md`).
**Out of scope:** Long-press notification → in-app expanded preview (planned for a separate Spec 2 — iOS Notification Content Extension).

## Problem

Compact message previews (push body, chat list lastMessage cell, noti tab item) render with a literal `> Forwarded from @user\n\n` markdown-blockquote prefix in front of the body. This:

- Looks like a leaked formatting token instead of a styled label.
- Wastes vertical space on the iOS push banner (two lines for the prefix + blank line + content).
- Provides no image preview when the message has an attachment — the user sees `> Forwarded from @user` plus a caption, with no visual hint that there's a photo/video.
- Is inconsistent with the polish of comparable apps (Telegram, iMessage).

The fix should also unify how non-forward messages render image/video/file previews on the same surfaces, since the current behavior leaves attachments un-previewed in chat lists and push body.

## Reference

Telegram conventions observed by the user (screenshots in the brainstorming session):

- iOS push notification uses Apple's standard `UNNotificationAttachment` — thumbnail appears on the **right** of the collapsed banner; long-press auto-expands to full image. No custom Notification Content Extension.
- Body text is `📷 Photo` / `🎥 Video` / `📎 File` for media-only messages, or the caption text if the media has one.
- Forwarded messages attribute the **original author**, not intermediate forwarders (forwarding through a chain shows only the original sender's name).

## Format rules (apply to all 4 surfaces)

A single text-format function produces the compact preview from a message. The output is consumed by:

| Surface | Consumer |
|---|---|
| iOS push body | Notification Service Extension (post-formatting before display) |
| iOS in-app chat list | Conversation row's `lastMessage` text view |
| Extension chat list | Conversation row's `lastMessage` text view |
| Extension Noti tab | Notification item preview line |

### Body text rules

| Message contents | Output |
|---|---|
| Text only | `text` |
| Image only | `📷 Photo` |
| Image + caption | `caption` |
| Video only | `🎥 Video` |
| Video + caption | `caption` |
| File only | `📎 filename.ext` |
| Voice message | `🎙 Voice message` |
| GIF / sticker | `🎞 GIF` / `📌 Sticker` (one each) |
| Other (link card, etc.) | fall back to existing renderer |

If the message is **forwarded**, prepend `↪ @originalAuthor: ` to whatever body would otherwise be produced. Forward chain attribution always uses the original author (not the immediate forwarder, not the chain). This matches the Telegram model.

If the conversation is a **group**, prefix the body with the immediate sender's username (no `@` prefix, matching the current chat-list convention seen in extension screenshots, e.g. `hieuna1111: ...`):

```
Bob: ↪ @C: Caption text
```

The forward prefix uses the original author's username with a leading `@`; the group sender prefix uses the username without `@`. This mirrors the existing visual convention.

### Image/video thumbnail rules

| Surface | Thumbnail position |
|---|---|
| iOS push (collapsed banner) | Apple-default — right side, via `UNNotificationAttachment` |
| iOS push (long-press) | Apple-default — auto-expanded full image |
| iOS in-app chat list | Inline left of the preview text, ~18×18 px, 3 px corner radius |
| Extension chat list | Inline left of the preview text, ~18-20 px, 3 px corner radius |
| Extension Noti tab | Inline left of the preview text, same sizing as chat list |

Localization: media labels (`Photo`, `Video`, `File`, `Voice message`) stay in English on all surfaces, matching Telegram's convention. The forward arrow `↪` and the `@username` token are also unlocalized.

## Architecture

### Single source of truth: `previewFormat(message) -> (text: String, thumb: ThumbRef?)`

A pure function that takes a message DTO and returns:

- `text` — the formatted body string per the rules above.
- `thumb` — an optional reference to the image/video thumbnail (URL + dimensions for chat lists, or attachment file URL for the iOS push NSE pipeline).

This function is implemented **once per platform** (one Swift impl in iOS, one TS impl shared by extension chat list + noti tab + webapp backend payload formatter). Shape is identical so behavior matches.

### Per-surface integration

**iOS push (Notification Service Extension)**
- NSE receives the APNS payload, calls `previewFormat` on the embedded message, sets `bestAttemptContent.body` to the result text, and downloads + attaches the thumbnail (existing NSE attachment download path) if `thumb` is present.
- Backend payload must include: `message.text`, `message.attachments[]` (type + URL + thumbnail URL), `message.forwardedFromOriginalAuthor` (string username, may be null), `message.senderDisplayName`, and `conversation.isGroup`. **If any of these are missing today, that's a backend prerequisite called out in the implementation plan.**

**iOS in-app chat list**
- The `ConversationRow` view's preview Text composes: optional inline thumbnail view (`AsyncImage` with placeholder) + the `previewFormat(message).text`.
- The thumbnail uses the existing media URL field; if absent, no thumbnail is rendered.

**Extension chat list / Noti tab**
- Same composition as iOS, in TSX. Thumbnail is a small `<img>` with `border-radius: 3px`, `width: 18px`, `height: 18px`, rendered inline with `display: inline-flex; gap: 6px; align-items: center`.

### Backend changes

Two pieces of data may need plumbing:

1. **Original-author username** for forwarded messages. The current APNS payload (verified by inspection during planning) emits `> Forwarded from @user\n\n<body>` as a single string in `aps.alert.body`. We change this to emit a structured `forwardedFromOriginalAuthor` field plus a clean `text` field, and let the NSE format the final body. This is a one-time payload-shape change.
2. **Attachment URL + thumbnail URL** in the APNS payload, so NSE can download the thumbnail. If today's payload already carries this for non-forward messages, no extra work; if it strips attachments on forward, we add them back.

Implementation plan will verify these two against the live backend before estimating scope.

## Components

### iOS

- `MessagePreviewFormatter.swift` (new) — pure `previewFormat(message:)` function plus pure helpers for media-label and forward-prefix composition. Unit-testable with no UIKit dependency.
- `NotificationService.swift` (existing NSE) — replace its current body-construction path with `previewFormat` + attachment download.
- `ConversationRow.swift` (existing) — replace its current `lastMessage` text composition with `previewFormat` + inline thumbnail view.

### Extension / Webapp

- `messagePreview.ts` (new, in shared utils) — TypeScript twin of `previewFormat`, same shape and rules.
- `ChatListItem.tsx` (existing) — use `messagePreview()` + inline `<img>` thumbnail.
- `NotificationItem.tsx` (existing) — same as above for noti-tab rows.
- Backend payload formatter (`pushNotificationPayload.ts` or equivalent) — emit structured fields (`text`, `forwardedFromOriginalAuthor`, `attachmentThumbUrl`) instead of pre-formatted `body`.

## Data flow (push notification)

1. Webapp/backend constructs APNS payload with structured fields.
2. APNS delivers to device.
3. iOS Notification Service Extension wakes, calls `previewFormat()` on the structured message.
4. NSE sets `body` to formatted text.
5. NSE downloads thumbnail URL (if any), saves to temp dir, attaches via `UNNotificationAttachment`.
6. NSE calls completion handler; Apple displays banner with right-side thumbnail.
7. Long-press → Apple's default expanded view shows full attachment image.

## Testing

- Unit tests for `MessagePreviewFormatter` (Swift) and `messagePreview` (TS), one test per row of the Body Text Rules table, plus group/DM × forward/non-forward × media-type combinations.
- Snapshot tests for `ConversationRow` with each of: text-only, image-only, image+caption, forward-text, forward-image, group-non-forward, group-forward.
- Manual verification: send each message variant from a second account, observe push banner (locked + unlocked), in-app chat list, extension chat list, extension noti tab. Capture screenshots for the PR.
- Automated push test via `xcrun simctl push` with a JSON payload mimicking the new structured shape, to validate the NSE path without depending on backend changes landing first.

## Error handling

- If the APNS payload is missing `forwardedFromOriginalAuthor` while flagged as forwarded, fall back to the immediate sender's username (best-effort, don't drop the message).
- If thumbnail download fails or times out (NSE has 30s budget), display the formatted body without the attachment — never block notification delivery on the image.
- Extension chat list: if thumbnail URL 404s, the inline `<img>` falls back to a generic placeholder block (same dimensions, gray fill) so the row layout doesn't shift.

## Migration

- The format change is server-driven (backend emits new structured payload) plus client-driven (NSE + chat-list views consume the new shape). Old clients on a new payload will see a less-pretty `lastMessage` because they still expect the legacy `> Forwarded from` string — but they won't crash, just render whatever `text` field is present. Versions older than the iOS minimum supported (gated by the in-app update gate) are out of support, so no backwards-compat shim is needed.
- For the extension/webapp, the change ships atomically with the new payload shape since both are in the same release pipeline.

## Open questions

- None remaining after brainstorming. The chain-attribution choice (original author only) and the localization choice (English media labels) are settled.

## Implementation order (preview, finalized in plan)

1. Implement `MessagePreviewFormatter` (Swift) + `messagePreview` (TS) with unit tests — pure functions, low risk.
2. Update backend APNS payload to structured shape, behind a feature flag.
3. Update iOS NSE to consume new shape.
4. Update iOS in-app `ConversationRow`.
5. Update extension `ChatListItem` and `NotificationItem`.
6. Flip flag, monitor, retire old payload path.

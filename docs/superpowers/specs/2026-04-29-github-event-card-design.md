# GitHub Event Card — Design Spec

**Date:** 2026-04-29
**Issue:** [#94 — Wrong UI rendering for Event Issue in Repository](https://github.com/GitchatSH/gitchat-ios-native/issues/94)
**Branch:** `fix/event-issue-rendering`
**Owner:** @nakamoto-hiru

## Problem

GitHub events (issue opened, PR merged, etc.) arrive in chat as raw JSON strings stored in `message.content`:

```
{"eventType":"issue_opened","title":"[Bug] Clicking wave notification fires error toast instead of opening DM","url":"https://github.com/.../issues/201","actor":"norwayiscoming","githubEventId":"8815949909"}
```

Because `ChatMessageView` treats every message as plain text, the JSON is rendered verbatim — broken layout, unreadable, and the URL is not actionable.

## Goal

Render any chat message whose `content` is a recognized GitHub event payload as a styled card. Plain text messages remain unchanged. The card is full-width, tappable, and opens the event URL in an in-app browser.

## Scope

**In scope (this PR):**
- Detect JSON event payloads and render `GitHubEventCard` instead of plain text.
- Detail style for `issue_opened` (icon, color, verb).
- Generic fallback styling for any other `eventType` so JSON never leaks to the UI again.
- Tap → open `url` in `SFSafariViewController`.
- Graceful fallback to plain text on malformed JSON or missing required fields.

**Out of scope:**
- Detail styling for other event types (`pr_opened`, `issue_closed`, etc.) — added later by extending the mapping table.
- Avatar fetching for the actor.
- Any backend/notification model changes.
- Refactoring `ChatMessage` into a typed rich-content enum.

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Which event types to support? | Hybrid: detail style for `issue_opened`, generic fallback for everything else with an `eventType`. |
| 2 | How does the user open the event? | Whole card tappable, small `arrow.up.forward` hint icon. URL opens in `SFSafariViewController`. |
| 3 | Where does the card sit in chat? | Full-width banner (16pt margin from chat edges). No avatar, no incoming/outgoing alignment. |
| 4 | Visual treatment | Keep the orange left accent bar from the web reference. SF Symbol icon at title start. |
| 5 | Card content | Title (2 lines, truncate), timestamp top-trailing, meta line `@actor • opened issue`. No "View on GitHub" link — the whole card is the link. |
| 6 | Where to parse JSON? | Inline at the view layer in `ChatMessageView` (no model refactor). |

## Architecture

### Data flow

```
backend → message.content (JSON string)
           ↓ ChatMessageView (around current line 488)
           ↓ heuristic: trimmed content starts with "{"
           ↓ JSONDecoder().decode(GitHubEventPayload.self, ...)
           ✓ success + has title + has eventType  → GitHubEventCard(payload:, timestamp:)
           ✗ otherwise                            → existing plain-text bubble path
```

The heuristic check (`first non-whitespace char is "{"`) avoids running `JSONDecoder` on every plain-text message.

### File structure

```
GitchatIOS/Features/Conversations/ChatDetail/Message/
├── ChatMessageView.swift              # modified: detection + branch
├── GitHubEventCard.swift              # NEW: SwiftUI view
└── GitHubEventPayload.swift           # NEW: Codable struct + GitHubEventStyle mapping
```

### Types

```swift
struct GitHubEventPayload: Decodable {
    let eventType: String
    let title: String
    let url: String?            // optional — card still renders without tap if missing
    let actor: String?          // optional — meta line shows "Someone" if missing
    let githubEventId: String?  // not used yet, kept for future dedupe
}

struct GitHubEventStyle {
    let icon: String   // SF Symbol name
    let color: Color
    let verb: String   // "opened issue", "closed pr", ...

    static func from(eventType: String) -> Self
}
```

### Detection (in `ChatMessageView`)

```swift
private func tryParseGitHubEvent(_ raw: String) -> GitHubEventPayload? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{",
          let data = trimmed.data(using: .utf8),
          let payload = try? JSONDecoder().decode(GitHubEventPayload.self, from: data),
          !payload.title.isEmpty,
          !payload.eventType.isEmpty
    else { return nil }
    return payload
}
```

If `tryParseGitHubEvent` returns non-nil, render `GitHubEventCard`. Otherwise, the existing rendering path is unchanged.

## Visual design

```
┌─────────────────────────────────────────────────────────┐
│■│  🟠  [Bug] Clicking wave notification          02:20 PM│
│■│      fires error toast instead of...                  │
│■│                                                        │
│■│      @norwayiscoming • opened issue                 ↗ │
└─────────────────────────────────────────────────────────┘
 ↑
 3pt accent bar (full-height)
```

### Spec

| Element | Value |
|---|---|
| Card horizontal margin (from chat edges) | 16pt |
| Corner radius | 12pt |
| Background | `Color(.tertiarySystemBackground)` |
| Accent bar | 3pt wide, full card height, color = event accent |
| Internal padding (after accent bar) | 12pt horizontal, 10pt vertical |
| Title icon | SF Symbol, 16pt, color = event accent |
| Title font | `.subheadline.weight(.semibold)`, `lineLimit(2)`, `.truncationMode(.tail)` |
| Timestamp | `.caption2`, `.secondary`, top-trailing in title row |
| Meta line | `.caption`, `.secondary`, 6pt below title row |
| Tap-hint icon | SF Symbol `arrow.up.forward`, 11pt, `.tertiary` opacity, end of meta row |
| Vertical spacing between consecutive event cards | 4pt |

### Layout (SwiftUI sketch)

```swift
HStack(spacing: 0) {
    Rectangle()
        .fill(style.color)
        .frame(width: 3)
    VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .font(.subheadline)
            Text(payload.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(timestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 4) {
            Text(metaLine) // "@actor • opened issue" or "Someone • opened issue"
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if payload.url != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
}
.frame(maxWidth: .infinity, alignment: .leading)
.background(Color(.tertiarySystemBackground))
.clipShape(RoundedRectangle(cornerRadius: 12))
.padding(.horizontal, 16)
```

The whole card is wrapped in a `Button(action: openURL)` with `.buttonStyle(.plain)`. The button is disabled when `payload.url == nil`.

### iOS specifics

- **Dynamic Type:** typography uses semantic styles (`.subheadline`, `.caption`, `.caption2`), so it scales with the user's accessibility settings.
- **Dark mode:** `tertiarySystemBackground` and `.secondary` foregrounds adapt automatically.
- **Pressed state:** `.opacity(0.7)` while pressed.
- **Accessibility:** `accessibilityLabel("\(verb.capitalized) by \(actor ?? "someone"): \(title)")`, `accessibilityHint("Opens on GitHub")`. The card is a single accessibility element.

## Event type mapping

### Detail style (this PR)

| eventType | Icon | Accent color | Verb |
|---|---|---|---|
| `issue_opened` | `circle.dotted` | `.systemOrange` | `opened issue` |

### Generic fallback (this PR — applies to every other `eventType`)

| Element | Value |
|---|---|
| Icon | `dot.radiowaves.left.and.right` |
| Accent color | `.secondary` |
| Verb | Humanized from `eventType`: split on `_`, swap noun/verb order, lowercase. Examples: `pr_opened` → `opened pr`, `issue_closed` → `closed issue`. If the eventType has no `_`, fall back to the raw string. |

When a future PR wants to give `pr_opened` (or any other event) detail styling, it adds a row to the mapping table — no other code changes required.

## Edge cases

| Case | Behavior |
|---|---|
| `content` is plain text (no `{`) | Existing plain-text bubble (no change). |
| JSON decode fails | Fall back to plain text (preserves data, no crash). |
| Decode succeeds but `title` is empty | Fall back to plain text (nothing meaningful to show). |
| Decode succeeds but `url` is missing | Render card, omit chevron, disable tap. |
| Decode succeeds but `actor` is missing | Meta line: `Someone • <verb>`. |
| `eventType` not in detail mapping | Generic fallback styling. |
| Title overflows 2 lines | Truncate with `…`. |
| Tap with no network | `SFSafariViewController` shows its native error UI — no app-side handling. |

## Testing notes

- Manual test cases:
  - `issue_opened` event renders with orange accent and detail styling.
  - An unknown eventType (e.g., `pr_opened`) renders with generic gray fallback — no JSON visible.
  - Malformed JSON (e.g., `{not valid}`) renders as plain text.
  - Plain text message starting with a `{` character (rare but possible) does not break — falls back to plain text on decode failure.
  - Missing `url` → card shows, no chevron, tap is a no-op.
  - Missing `actor` → meta reads `Someone • opened issue`.
  - Long title is truncated to 2 lines.
  - Light + dark mode visual check.
  - Dynamic Type at largest size still readable, no clipping.

## Risks / open questions

- **None blocking.** The change is additive: existing plain-text rendering is the default fallback, and parsing is gated behind a cheap heuristic.
- Time format for the timestamp follows whatever the existing chat metadata helper produces (e.g., `02:20 PM`). The card consumes a pre-formatted string from `ChatMessageView`, so no new date-formatting logic is introduced here.

## Out of scope (future PRs)

- Detail styling for `pr_opened`, `pr_merged`, `pr_closed`, `issue_closed`, `release_published`, `push`, etc.
- Showing the actor's GitHub avatar inline.
- Repo name display when there are multiple repos in one chat.
- Migrating `ChatMessage.content` to a typed rich-content enum.

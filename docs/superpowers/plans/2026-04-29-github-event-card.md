# GitHub Event Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render GitHub event JSON payloads in chat as a styled full-width card instead of raw JSON text. Detail style for `issue_opened`; generic fallback for any other `eventType`.

**Architecture:** Inline detection in `ChatMessageView.body`. When `message.content` decodes into a `GitHubEventPayload`, render `GitHubEventCard` (full-width banner with orange accent bar, SF Symbol icon, title, actor + verb meta) and short-circuit the normal bubble layout. Plain-text path is unchanged.

**Tech Stack:** Swift, SwiftUI, XCTest. Uses existing `Environment(\.openURL)` (intercepted by `ChatDetailView` to present `SafariSheet` / SFSafariViewController).

**Spec:** `docs/superpowers/specs/2026-04-29-github-event-card-design.md`

---

## File structure

```
GitchatIOS/Features/Conversations/ChatDetail/Message/
├── ChatMessageView.swift              # MODIFY: body short-circuit + helper
├── GitHubEventCard.swift              # NEW: SwiftUI view
└── GitHubEventPayload.swift           # NEW: Codable + GitHubEventStyle + tryParse helper

GitchatIOSTests/
└── GitHubEventPayloadTests.swift      # NEW: decoding + style + detection tests
```

Test target module name (from `project.yml`): `Gitchat` (used in `@testable import Gitchat`).

---

## Task 1: GitHubEventPayload Codable struct + decoding tests

**Files:**
- Create: `GitchatIOSTests/GitHubEventPayloadTests.swift`
- Create: `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift`

- [ ] **Step 1: Write the failing decoder test**

Create `GitchatIOSTests/GitHubEventPayloadTests.swift`:

```swift
import XCTest
@testable import Gitchat

final class GitHubEventPayloadTests: XCTestCase {

    private func decode(_ json: String) throws -> GitHubEventPayload {
        try JSONDecoder().decode(GitHubEventPayload.self, from: Data(json.utf8))
    }

    func testFullPayloadDecodes() throws {
        let json = """
        {"eventType":"issue_opened","title":"[Bug] Wave fires toast",\
        "url":"https://github.com/org/repo/issues/201","actor":"alice",\
        "githubEventId":"8815949909"}
        """
        let p = try decode(json)
        XCTAssertEqual(p.eventType, "issue_opened")
        XCTAssertEqual(p.title, "[Bug] Wave fires toast")
        XCTAssertEqual(p.url, "https://github.com/org/repo/issues/201")
        XCTAssertEqual(p.actor, "alice")
        XCTAssertEqual(p.githubEventId, "8815949909")
    }

    func testMissingOptionalsDecodes() throws {
        let json = """
        {"eventType":"issue_opened","title":"x"}
        """
        let p = try decode(json)
        XCTAssertNil(p.url)
        XCTAssertNil(p.actor)
        XCTAssertNil(p.githubEventId)
    }

    func testMissingRequiredFails() {
        let json = """
        {"title":"no event type"}
        """
        XCTAssertThrowsError(try decode(json))
    }
}
```

- [ ] **Step 2: Run tests — verify they fail to compile**

Run in Xcode: ⌘U on `GitchatIOSTests/GitHubEventPayloadTests`.
Expected: build error "Cannot find 'GitHubEventPayload' in scope".

- [ ] **Step 3: Create the struct**

Create `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift`:

```swift
import Foundation

struct GitHubEventPayload: Decodable, Equatable {
    let eventType: String
    let title: String
    let url: String?
    let actor: String?
    let githubEventId: String?
}
```

- [ ] **Step 4: Regenerate the Xcode project**

The project uses XcodeGen with source-path globbing — any `.swift` file dropped under `GitchatIOS/` (and `GitchatIOSTests/`) is auto-picked up after regeneration.

Run: `xcodegen generate`
Expected: `Generated project successfully` and `GitchatIOS.xcodeproj/project.pbxproj` is updated.

- [ ] **Step 5: Run the tests — verify they pass**

Run: ⌘U on `GitHubEventPayloadTests` (or via CLI: `xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:GitchatIOSTests/GitHubEventPayloadTests`).
Expected: all 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift \
        GitchatIOSTests/GitHubEventPayloadTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(ios): GitHubEventPayload Codable struct + decoder tests"
```

---

## Task 2: GitHubEventStyle mapping (icon / color / verb)

**Files:**
- Modify: `GitchatIOSTests/GitHubEventPayloadTests.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift`

- [ ] **Step 1: Write failing tests for GitHubEventStyle**

Append to `GitHubEventPayloadTests.swift`:

```swift
final class GitHubEventStyleTests: XCTestCase {

    func testIssueOpenedHasDetailStyle() {
        let s = GitHubEventStyle.from(eventType: "issue_opened")
        XCTAssertEqual(s.icon, "circle.dotted")
        XCTAssertEqual(s.verb, "opened issue")
        // Color is .orange — compare via description since SwiftUI Color
        // doesn't expose a direct equality channel.
        XCTAssertEqual(String(describing: s.color), String(describing: Color.orange))
    }

    func testUnknownEventUsesGenericFallback() {
        let s = GitHubEventStyle.from(eventType: "pr_opened")
        XCTAssertEqual(s.icon, "dot.radiowaves.left.and.right")
        XCTAssertEqual(s.verb, "opened pr")
        XCTAssertEqual(String(describing: s.color), String(describing: Color.secondary))
    }

    func testHumanizeSwapsNounAndVerb() {
        XCTAssertEqual(GitHubEventStyle.humanize("issue_closed"), "closed issue")
        XCTAssertEqual(GitHubEventStyle.humanize("pr_merged"), "merged pr")
    }

    func testHumanizeFallsBackForNoUnderscore() {
        XCTAssertEqual(GitHubEventStyle.humanize("push"), "push")
    }

    func testHumanizeHandlesMultipleUnderscores() {
        // "release_published" → object="release", verb="published"
        XCTAssertEqual(GitHubEventStyle.humanize("release_published"), "published release")
    }
}
```

Add `import SwiftUI` to the top of the test file (alongside the existing `import XCTest`).

- [ ] **Step 2: Run tests — verify they fail**

Run: ⌘U on `GitHubEventStyleTests`.
Expected: build error "Cannot find 'GitHubEventStyle' in scope".

- [ ] **Step 3: Implement GitHubEventStyle**

Append to `GitHubEventPayload.swift`:

```swift
import SwiftUI

struct GitHubEventStyle: Equatable {
    let icon: String     // SF Symbol
    let color: Color
    let verb: String     // e.g. "opened issue"

    static func from(eventType: String) -> GitHubEventStyle {
        switch eventType {
        case "issue_opened":
            return GitHubEventStyle(
                icon: "circle.dotted",
                color: .orange,
                verb: "opened issue"
            )
        default:
            return GitHubEventStyle(
                icon: "dot.radiowaves.left.and.right",
                color: .secondary,
                verb: humanize(eventType)
            )
        }
    }

    /// `pr_opened` → `opened pr`. `push` → `push` (no underscore = pass through).
    /// First component is treated as the object, second as the verb; they swap.
    static func humanize(_ eventType: String) -> String {
        let parts = eventType.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return eventType }
        return "\(parts[1]) \(parts[0])"
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: ⌘U on `GitHubEventStyleTests`.
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift \
        GitchatIOSTests/GitHubEventPayloadTests.swift
git commit -m "feat(ios): GitHubEventStyle mapping (icon/color/verb) with humanize fallback"
```

---

## Task 3: Detection helper `tryParse` with required-field gating

**Files:**
- Modify: `GitchatIOSTests/GitHubEventPayloadTests.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift`

- [ ] **Step 1: Write failing detection tests**

Append to `GitHubEventPayloadTests.swift`:

```swift
final class GitHubEventDetectionTests: XCTestCase {

    func testPlainTextReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse("hello world"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse(""))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse("{not valid json"))
    }

    func testValidPayloadReturnsStruct() {
        let raw = #"{"eventType":"issue_opened","title":"Hi","url":"https://x","actor":"a"}"#
        let p = GitHubEventPayload.tryParse(raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.title, "Hi")
    }

    func testEmptyTitleReturnsNil() {
        let raw = #"{"eventType":"issue_opened","title":"","url":"https://x","actor":"a"}"#
        XCTAssertNil(GitHubEventPayload.tryParse(raw))
    }

    func testEmptyEventTypeReturnsNil() {
        let raw = #"{"eventType":"","title":"hi","url":"https://x","actor":"a"}"#
        XCTAssertNil(GitHubEventPayload.tryParse(raw))
    }

    func testLeadingWhitespaceStillParses() {
        let raw = "   \n" + #"{"eventType":"issue_opened","title":"Hi"}"#
        XCTAssertNotNil(GitHubEventPayload.tryParse(raw))
    }

    func testTextStartingWithBraceButNotJSONReturnsNil() {
        // Edge: someone literally typed "{hello}" as a chat message.
        XCTAssertNil(GitHubEventPayload.tryParse("{hello}"))
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: ⌘U on `GitHubEventDetectionTests`.
Expected: build error "Type 'GitHubEventPayload' has no member 'tryParse'".

- [ ] **Step 3: Implement tryParse**

Append to `GitHubEventPayload.swift`:

```swift
extension GitHubEventPayload {
    /// Returns a payload only when `raw` looks like a GitHub event JSON object
    /// with non-empty `eventType` and `title`. Otherwise nil — the caller
    /// should fall back to plain-text rendering.
    static func tryParse(_ raw: String) -> GitHubEventPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GitHubEventPayload.self, from: data),
              !payload.eventType.isEmpty,
              !payload.title.isEmpty
        else { return nil }
        return payload
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: ⌘U on `GitHubEventDetectionTests`.
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventPayload.swift \
        GitchatIOSTests/GitHubEventPayloadTests.swift
git commit -m "feat(ios): GitHubEventPayload.tryParse with required-field gating"
```

---

## Task 4: GitHubEventCard SwiftUI view

**Files:**
- Create: `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventCard.swift`

No XCTest — SwiftUI view verified via `#Preview` in Xcode canvas. Visual sign-off in Task 6.

- [ ] **Step 1: Create the view file**

Create `GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventCard.swift`:

```swift
import SwiftUI

struct GitHubEventCard: View {
    let payload: GitHubEventPayload
    let timestamp: String?     // pre-formatted, e.g. "02:20 PM"

    @Environment(\.openURL) private var openURL

    private var style: GitHubEventStyle {
        GitHubEventStyle.from(eventType: payload.eventType)
    }

    private var metaLine: String {
        let who = payload.actor.map { "@\($0)" } ?? "Someone"
        return "\(who) • \(style.verb)"
    }

    private var tappableURL: URL? {
        payload.url.flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: handleTap) {
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
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if let timestamp, !timestamp.isEmpty {
                            Text(timestamp)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if tappableURL != nil {
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
        }
        .buttonStyle(.plain)
        .disabled(tappableURL == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.verb.capitalized) by \(payload.actor ?? "someone"): \(payload.title)")
        .accessibilityHint(tappableURL == nil ? "" : "Opens on GitHub")
    }

    private func handleTap() {
        if let url = tappableURL { openURL(url) }
    }
}

#Preview("Issue opened") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "issue_opened",
            title: "[Bug] Clicking wave notification fires error toast instead of opening DM",
            url: "https://github.com/org/repo/issues/201",
            actor: "norwayiscoming",
            githubEventId: "8815949909"
        ),
        timestamp: "02:20 PM"
    )
    .padding(.horizontal, 16)
}

#Preview("Unknown event (fallback)") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "pr_opened",
            title: "Add Telegram-style forwarded header",
            url: "https://github.com/org/repo/pull/96",
            actor: "vincent-xbt",
            githubEventId: nil
        ),
        timestamp: "07:50 PM"
    )
    .padding(.horizontal, 16)
}

#Preview("Missing url + actor") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "issue_opened",
            title: "Stop send email",
            url: nil,
            actor: nil,
            githubEventId: nil
        ),
        timestamp: "07:10 AM"
    )
    .padding(.horizontal, 16)
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Generated project successfully`. The new file is now in the `Gitchat` target.

- [ ] **Step 3: Visual check in Xcode preview canvas**

Open `GitHubEventCard.swift` in Xcode. Activate the canvas (⌥⌘↩).
Expected:
- "Issue opened" preview: orange 3pt left bar, orange `circle.dotted` icon, bold title (2 lines, truncated with "…"), "02:20 PM" top-right, "@norwayiscoming • opened issue" + faint `↗` icon.
- "Unknown event (fallback)" preview: gray bar, gray `dot.radiowaves.left.and.right` icon, "@vincent-xbt • opened pr".
- "Missing url + actor" preview: orange bar, no `↗` icon, meta line reads "Someone • opened issue".
- Toggle dark mode (canvas color scheme switcher): card background still readable.

- [ ] **Step 4: Build the app — verify no warnings**

Run: ⌘B on the `Gitchat` scheme.
Expected: build succeeds, no new warnings from `GitHubEventCard.swift`.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/GitHubEventCard.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(ios): GitHubEventCard view with previews"
```

---

## Task 5: Wire detection into `ChatMessageView.body`

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

This task short-circuits the normal bubble layout when the message content is a recognized GitHub event payload. Card is full-width (16pt margin from chat edges), no avatar column.

- [ ] **Step 1: Add a computed event-payload property**

Open `ChatMessageView.swift`. Just above `var body: some View {` (line 108), add:

```swift
private var githubEventPayload: GitHubEventPayload? {
    GitHubEventPayload.tryParse(message.content)
}
```

- [ ] **Step 2: Short-circuit `body` when the payload is present**

Replace the existing `body` (currently line 108–128) with:

```swift
var body: some View {
    if let payload = githubEventPayload {
        eventCardRow(payload: payload)
            .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
            .onAppear(perform: onFirstAppear)
    } else if isInsideGroup {
        // Inside a grouped sender cell — just the bubble, no avatar/spacers.
        // The parent group cell provides the avatar column.
        bubbleColumn
            .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
            .onAppear(perform: onFirstAppear)
    } else {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer(minLength: 40)
            } else if isGroup {
                avatarColumn
            }
            bubbleColumn
            if !isMe { Spacer(minLength: 40) }
        }
        .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
        .onAppear(perform: onFirstAppear)
    }
}

@ViewBuilder
private func eventCardRow(payload: GitHubEventPayload) -> some View {
    GitHubEventCard(payload: payload, timestamp: message.shortTime)
        .padding(.horizontal, 16)
}
```

- [ ] **Step 3: Build the app**

Run: ⌘B.
Expected: build succeeds.

- [ ] **Step 4: Run the full test suite**

Run: ⌘U on `GitchatIOSTests` scheme.
Expected: all existing tests still PASS, plus the 16 new tests from Tasks 1–3 PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift
git commit -m "feat(ios): render GitHub event payloads as cards in chat (fixes #94)"
```

---

## Task 6: Manual smoke verification on simulator

**Files:** none (manual QA)

- [ ] **Step 1: Run the app on iOS simulator**

Run: ⌘R on the `Gitchat` scheme, target an iPhone 15 simulator (or any iPhone running iOS 17+).

- [ ] **Step 2: Open a conversation that contains GitHub event messages**

Navigate to a chat with the events shown in issue #94 screenshot (e.g. the `gitchat_extension` group).

- [ ] **Step 3: Verify the rendering checklist**

Confirm visually:
- [ ] No raw JSON visible anywhere in the message list.
- [ ] `issue_opened` events: orange accent bar + orange `circle.dotted` icon + bold title (≤2 lines, truncated with "…" if longer) + timestamp top-right + `@actor • opened issue` meta + faint `↗` chevron.
- [ ] Other event types (e.g. `pr_opened` if present): gray accent bar + gray signal icon + humanized verb (`opened pr`).
- [ ] Card spans full width, 16pt margin from screen edges.
- [ ] Day separators ("Yesterday", "Today") above the cards still render.
- [ ] A card with no `url` shows no chevron and is not tappable.

- [ ] **Step 4: Tap an event card**

Tap any event card with a URL.
Expected: in-app `SafariSheet` (SFSafariViewController) opens with the GitHub URL. Closing returns to the chat unchanged.

- [ ] **Step 5: Toggle dark / light mode**

Settings → Developer → Dark Appearance. Re-open the chat in each mode.
Expected: card background is readable in both modes; accent bar color stays orange/gray; all text legible.

- [ ] **Step 6: Dynamic Type at largest size**

Settings → Accessibility → Display & Text Size → Larger Text → max slider.
Expected: card text scales up; layout doesn't clip; title truncation still works.

- [ ] **Step 7: Send a plain-text message that starts with `{`**

In the same chat, send literal text `{just kidding}`.
Expected: renders as a normal text bubble — not as an event card. (Validates the malformed-JSON fallback.)

- [ ] **Step 8: Push the branch and open the PR**

```bash
git push -u origin fix/event-issue-rendering
gh pr create --title "fix(ios): render GitHub event payloads as cards (#94)" --body "$(cat <<'EOF'
## Summary
- Detect GitHub event JSON payloads in chat (`eventType` + `title` + optional `url` / `actor`) and render `GitHubEventCard` instead of raw JSON.
- Detail style for `issue_opened` (orange accent + dotted-circle icon). Generic gray fallback for any other `eventType` so JSON never reaches the UI.
- Whole card tappable → opens URL in the existing in-app `SafariSheet`.

Fixes #94.

Spec: `docs/superpowers/specs/2026-04-29-github-event-card-design.md`
Plan: `docs/superpowers/plans/2026-04-29-github-event-card.md`

## Test plan
- [ ] Issue events render with the detail card (orange).
- [ ] Other event types render with the gray fallback card (no JSON visible).
- [ ] Card tap opens SafariSheet.
- [ ] Plain-text messages and `{literal braces}` still render as regular bubbles.
- [ ] Light + dark mode legible.
- [ ] Dynamic Type at largest size doesn't clip.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the implementer

- **No model changes.** `ChatMessage.content` stays a `String`. All decoding lives in `GitHubEventPayload.tryParse`.
- **No new dependencies.** Uses Foundation + SwiftUI only.
- **Module name in tests** is `Gitchat` (not `GitchatIOS`) — see existing tests for the `@testable import Gitchat` pattern.
- **`xcodegen generate`** rebuilds `GitchatIOS.xcodeproj` from `project.yml`. Sources are globbed by path, so new `.swift` files under `GitchatIOS/` and `GitchatIOSTests/` are auto-included after running it.
- **`message.shortTime`** is the existing pre-formatted timestamp helper used elsewhere in `ChatMessageView` — reuse it; do not introduce a new `DateFormatter`.
- **`Environment(\.openURL)`** is already overridden in `ChatDetailView` (line 346) to route URLs into `SafariSheet`. The card just calls `openURL(url)`; the existing chain handles presentation.
- **Future event types** (e.g. `pr_opened`, `issue_closed`) are added later by extending the `switch` in `GitHubEventStyle.from(eventType:)`. No other code changes are needed.

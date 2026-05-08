# Compact Message Preview — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-08-compact-message-preview-design.md`
**Issue:** GitchatSH/gitchat-ios-native#129
**Branch:** `feat/compact-message-preview` (already created, has the spec commit)

**Goal:** Render compact message previews on (a) iOS push notifications and (b) the in-app chat list with: forward attribution as `↪ @user:`, a media-type label (`📷 Photo`, `🎥 Video`, `📎 file.ext`) when there's only an attachment, and an inline left-side thumbnail for image/video messages in the chat list.

**Architecture:** A pure `MessagePreviewFormatter` Swift type produces `(text: String, thumbURL: URL?)` from a message DTO. It's shared between the main app target and the OneSignal NSE target. The NSE writes the formatted text to `bestAttemptContent.body`; the chat list view composes an `HStack(thumbnail, Text(preview))`. Forward attribution prefers the new structured field `forwarded_from_original_author` from the backend; falls back to parsing the legacy `> Forwarded from @user\n\n` prefix from `body` so this lands without waiting on backend.

**Tech Stack:** SwiftUI, XCTest, XcodeGen (run `xcodegen generate` after adding files), iPhone 17 simulator (canonical sim per `CLAUDE.md`).

**Backend dependency:** Push payload + Message DTO need `forwarded_from_original_author` and `attachment_thumb_url`/`attachment_type` to render the prettiest version. The fallback path keeps this iOS plan independent — it ships immediately by parsing legacy `body`. Rendering upgrades automatically once `gitchat-webapp` lands its plan.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `GitchatIOS/Core/Utils/MessagePreviewFormatter.swift` | Create | Pure formatter: `(Message, isGroup, senderLogin?) -> (text: String, thumbURL: URL?)` |
| `GitchatIOS/Core/Models/Models.swift:338-356` | Modify | Add `forwarded_from_original_author: String?` to Message struct |
| `OneSignalNotificationServiceExtension/NotificationService.swift` | Modify | Apply formatter to `bestAttemptContent.body` after OneSignal enrichment |
| `GitchatIOS/Features/Conversations/ConversationsListView.swift:870-942` | Modify | Use formatter; add inline thumbnail next to preview text |
| `GitchatIOSTests/MessagePreviewFormatterTests.swift` | Create | Unit tests for every body-rule row |
| `project.yml` | Modify | Include `MessagePreviewFormatter.swift` in both main app target and NSE target |

---

## Task 1: Add `MessagePreviewFormatter`

**Files:**
- Create: `GitchatIOS/Core/Utils/MessagePreviewFormatter.swift`
- Create: `GitchatIOSTests/MessagePreviewFormatterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// GitchatIOSTests/MessagePreviewFormatterTests.swift
import XCTest
@testable import Gitchat

final class MessagePreviewFormatterTests: XCTestCase {
    func test_textOnly_dm_returnsTextAsIs() {
        let m = makeMessage(content: "hello")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "hello")
        XCTAssertNil(out.thumbURL)
    }

    func test_imageOnly_dm_returnsPhotoLabel() {
        let m = makeMessage(content: "", attachments: [att(type: "image", url: "https://x/1.jpg", thumbnailUrl: "https://x/1-t.jpg")])
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "📷 Photo")
        XCTAssertEqual(out.thumbURL, URL(string: "https://x/1-t.jpg"))
    }

    func test_imageWithCaption_dm_returnsCaption() {
        let m = makeMessage(content: "look at this", attachments: [att(type: "image", url: "https://x/1.jpg", thumbnailUrl: "https://x/1-t.jpg")])
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "look at this")
        XCTAssertEqual(out.thumbURL, URL(string: "https://x/1-t.jpg"))
    }

    func test_videoOnly_dm_returnsVideoLabel() {
        let m = makeMessage(content: "", attachments: [att(type: "video", url: "https://x/v.mp4", thumbnailUrl: "https://x/v-t.jpg")])
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "🎥 Video")
    }

    func test_fileOnly_dm_returnsFileLabel() {
        let m = makeMessage(content: "", attachments: [att(type: "file", url: "https://x/r.pdf", filename: "report.pdf")])
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "📎 report.pdf")
    }

    func test_forward_structured_dm_addsArrowPrefix() {
        let m = makeMessage(content: "look at this", forwardedFromOriginalAuthor: "alice")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "↪ @alice: look at this")
    }

    func test_forward_legacyPrefix_isParsedAndStripped() {
        // No structured field; relies on legacy `> Forwarded from @user\n\n` parsing
        let m = makeMessage(content: "> Forwarded from @alice\n\nlook at this")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "↪ @alice: look at this")
    }

    func test_group_addsSenderPrefix() {
        let m = makeMessage(content: "hello")
        let out = MessagePreviewFormatter.format(message: m, isGroup: true, senderLogin: "bob")
        XCTAssertEqual(out.text, "bob: hello")
    }

    func test_group_forward_addsBothPrefixes() {
        let m = makeMessage(content: "hi", forwardedFromOriginalAuthor: "carol")
        let out = MessagePreviewFormatter.format(message: m, isGroup: true, senderLogin: "bob")
        XCTAssertEqual(out.text, "bob: ↪ @carol: hi")
    }

    func test_emptyMessage_returnsEmpty() {
        let m = makeMessage(content: "")
        let out = MessagePreviewFormatter.format(message: m, isGroup: false, senderLogin: nil)
        XCTAssertEqual(out.text, "")
    }

    // Helpers — match the actual Message and MessageAttachment shapes in Models.swift.
    private func makeMessage(
        content: String,
        attachments: [MessageAttachment]? = nil,
        forwardedFromOriginalAuthor: String? = nil
    ) -> Message {
        // Construct a Message instance using Models.swift's initializer.
        // Replace this with the exact init / decoder pattern used by the project.
        fatalError("Replace with real Message construction matching Models.swift")
    }
    private func att(type: String, url: String, thumbnailUrl: String? = nil, filename: String? = nil) -> MessageAttachment {
        fatalError("Replace with real MessageAttachment construction")
    }
}
```

The `makeMessage` / `att` helpers are placeholders — replace with the project's actual pattern (likely JSON-decode a small fixture, or a memberwise init if `Message` exposes one). Look at any existing test in `GitchatIOSTests/` that constructs a `Message` for the closest pattern.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/MessagePreviewFormatterTests
```

Expected: build fails (formatter doesn't exist) or all tests fail.

- [ ] **Step 3: Implement `MessagePreviewFormatter`**

```swift
// GitchatIOS/Core/Utils/MessagePreviewFormatter.swift
import Foundation

enum MessagePreviewFormatter {
    struct Output {
        let text: String
        let thumbURL: URL?
    }

    /// Compose a one-line preview string for a message.
    /// - Parameters:
    ///   - message: the message DTO
    ///   - isGroup: true if the message belongs to a group/team/community conversation
    ///   - senderLogin: the immediate sender's login (used as `Bob: ` prefix in groups)
    static func format(message: Message, isGroup: Bool, senderLogin: String?) -> Output {
        let raw = message.content ?? ""

        // Forward attribution: prefer structured field; fall back to parsing legacy
        // `> Forwarded from @user\n\n` prefix from the body.
        let (originalAuthor, bodyAfterForward): (String?, String) = {
            if let structured = message.forwarded_from_original_author, !structured.isEmpty {
                return (structured, stripLegacyForwardPrefix(raw))
            }
            return parseLegacyForwardPrefix(raw)
        }()

        // Media label: empty body + attachment → label; attachment + caption → caption.
        let mediaLabeledBody: String = {
            let trimmed = bodyAfterForward.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty, let firstAttachment = message.attachments?.first else {
                return bodyAfterForward
            }
            switch firstAttachment.type {
            case "image": return "📷 Photo"
            case "video": return "🎥 Video"
            case "voice": return "🎙 Voice message"
            case "file":  return "📎 \(firstAttachment.filename ?? "File")"
            default:      return bodyAfterForward
            }
        }()

        var text = mediaLabeledBody
        if let originalAuthor {
            text = "↪ @\(originalAuthor): \(text)"
        }
        if isGroup, let senderLogin {
            text = "\(senderLogin): \(text)"
        }

        let thumbURL: URL? = {
            guard let att = message.attachments?.first else { return nil }
            if let s = att.thumbnail_url, let u = URL(string: s) { return u }
            if let s = att.url, let u = URL(string: s) { return u }
            return nil
        }()

        return Output(text: text, thumbURL: thumbURL)
    }

    private static let legacyForwardRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:>\s+)?Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))(?:\n+|$)"#,
        options: []
    )

    private static func parseLegacyForwardPrefix(_ raw: String) -> (author: String?, rest: String) {
        guard let regex = legacyForwardRegex else { return (nil, raw) }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let authorRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range(at: 0), in: raw) else {
            return (nil, raw)
        }
        let author = String(raw[authorRange])
        let rest = String(raw[fullRange.upperBound...])
        return (author, rest)
    }

    private static func stripLegacyForwardPrefix(_ raw: String) -> String {
        return parseLegacyForwardPrefix(raw).rest
    }
}
```

- [ ] **Step 4: Add `forwarded_from_original_author` to `Message` struct**

In `GitchatIOS/Core/Models/Models.swift:338-356`, add the field to the `Message` struct. Match the existing `Codable` shape (snake_case JSON keys typically map via `CodingKeys` enum or via `JSONDecoder.keyDecodingStrategy`):

```swift
let forwarded_from_original_author: String?
```

Place it near `sender` and other forward-related fields. Update any explicit `init(...)` to include the new param with default `nil`.

- [ ] **Step 5: Add the file to both targets via XcodeGen**

In `project.yml`, ensure `GitchatIOS/Core/Utils/MessagePreviewFormatter.swift` is included in:
- `GitchatIOS` target (main app)
- `OneSignalNotificationServiceExtension` target (NSE)

If the project.yml uses path-globbing per-target, no change may be needed beyond putting the file under a folder that's already globbed — verify by inspection. Otherwise add an explicit `sources:` entry under the NSE target.

Then regenerate:

```bash
xcodegen generate
```

Verify both targets pick up the file:

```bash
grep -c "MessagePreviewFormatter.swift" GitchatIOS.xcodeproj/project.pbxproj
```

Expected: 4 (file ref + group entry + 2 build-file entries, one per target). If <4, fix `project.yml` and regenerate.

- [ ] **Step 6: Run tests**

```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/MessagePreviewFormatterTests
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Core/Utils/MessagePreviewFormatter.swift \
        GitchatIOS/Core/Models/Models.swift \
        GitchatIOSTests/MessagePreviewFormatterTests.swift \
        project.yml \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(preview): add MessagePreviewFormatter (refs #129)"
```

---

## Task 2: Apply formatter in OneSignal NSE

**Files:**
- Modify: `OneSignalNotificationServiceExtension/NotificationService.swift`

- [ ] **Step 1: Inspect the OneSignal payload shape**

Run:

```bash
rg -n "userInfo|custom\b|aps\b" OneSignalNotificationServiceExtension/
```

OneSignal puts the backend's `data` dict under `userInfo["custom"]["a"]` typically. Confirm by adding a one-shot `NSLog("payload: \\(request.content.userInfo)")` early in `didReceive(_:withContentHandler:)`, send a test push (`xcrun simctl push <udid> chat.git path/to/payload.apns`), and inspect `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.apple.UserNotifications"'`.

- [ ] **Step 2: Extract structured fields after OneSignal enrichment**

In `NotificationService.swift`, after `OneSignalExtension.didReceiveNotificationExtensionRequest(...)` returns `processed` (line 26-29), but before `applyCommunicationIntent`, build a transient `Message` from the structured fields and run the formatter:

```swift
OneSignalExtension.didReceiveNotificationExtensionRequest(
    request,
    with: bestAttemptContent
) { [weak self] processed in
    let formatted = self?.applyCompactPreview(content: processed, request: request) ?? processed
    var finalContent = self?.applyCommunicationIntent(to: formatted) ?? formatted
    finalContent = self?.silenceIfMuted(finalContent) ?? finalContent
    contentHandler(finalContent)
}
```

Then add the helper:

```swift
private func applyCompactPreview(content: UNNotificationContent, request: UNNotificationRequest) -> UNMutableNotificationContent {
    guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
        return UNMutableNotificationContent()
    }

    // OneSignal data lives under userInfo["custom"]["a"] (verify in Step 1)
    let custom = (request.content.userInfo["custom"] as? [String: Any]) ?? [:]
    let data = (custom["a"] as? [String: Any]) ?? [:]

    let forwardedFromOriginalAuthor = data["forwarded_from_original_author"] as? String
    let attachmentThumbUrl = data["attachment_thumb_url"] as? String
    let attachmentType = data["attachment_type"] as? String
    let senderLogin = data["sender_login"] as? String
    let isGroup = (data["is_group"] as? Bool) ?? false

    // Build a synthetic Message for the formatter. We pass the original body
    // (which may still carry the legacy `> Forwarded from` prefix on older
    // backend versions); the formatter strips it.
    let synthetic = Message(
        // ... fill the minimum required fields, leaving the rest at default.
        content: mutable.body,
        sender: senderLogin ?? "",
        attachments: attachmentThumbUrl.map { thumb in
            [MessageAttachment(
                type: attachmentType ?? "image",
                url: thumb,
                thumbnail_url: thumb,
                filename: nil
            )]
        },
        forwarded_from_original_author: forwardedFromOriginalAuthor
    )
    let out = MessagePreviewFormatter.format(
        message: synthetic,
        isGroup: isGroup,
        senderLogin: isGroup ? senderLogin : nil
    )
    mutable.body = out.text
    return mutable
}
```

If `Message` requires more fields than shown above, adjust the synthetic init — but keep this logic local to NSE; do **not** widen `Message`'s public init for NSE convenience.

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual push smoke test**

Create `/tmp/test-push.apns` with a payload mimicking the new shape:

```json
{
  "aps": { "alert": { "title": "NorwayIsHere", "body": "look at this" }, "mutable-content": 1, "sound": "default" },
  "custom": {
    "a": {
      "type": "chat_message",
      "actor_login": "norway",
      "sender_login": "norway",
      "is_group": false,
      "forwarded_from_original_author": "slugmacro",
      "attachment_thumb_url": "https://placekitten.com/200/200",
      "attachment_type": "image"
    }
  }
}
```

Then:

```bash
xcrun simctl push booted chat.git /tmp/test-push.apns
```

Expected: banner body reads `↪ @slugmacro: look at this`. (If the structured field is absent and `body` still has `> Forwarded from @slugmacro\n\nlook at this`, the legacy regex strips it and produces the same output.)

- [ ] **Step 5: Commit**

```bash
git add OneSignalNotificationServiceExtension/NotificationService.swift
git commit -m "feat(nse): format push body via MessagePreviewFormatter (refs #129)"
```

---

## Task 3: Update chat list preview composition

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:870-942`

- [ ] **Step 1: Replace `previewWithoutPhotoEmoji` and `lastPhotoURL` with formatter call**

Around lines 866-899, find the existing `lastPhotoURL` and `previewWithoutPhotoEmoji` computed properties. Replace both with a single computed property that calls the formatter — the formatter is the new source of truth for both the text and the thumb URL:

```swift
private var formattedPreview: MessagePreviewFormatter.Output {
    let last = cachedEntry?.messages.last(where: { $0.type == nil || $0.type == "user" })
        ?? conversation.last_message
    guard let last else {
        return .init(text: conversation.previewText ?? "", thumbURL: nil)
    }
    return MessagePreviewFormatter.format(
        message: last,
        isGroup: conversation.isGroup,
        senderLogin: conversation.isGroup ? last.sender : nil
    )
}
```

Update `previewAttributed` (line 936) to use it:

```swift
private var previewAttributed: AttributedString {
    var line = topicChipPrefix
    var body = AttributedString(formattedPreview.text)
    body.foregroundColor = secondaryTextColor
    line += body
    return line
}
```

Anywhere `lastPhotoURL` was read, replace with `formattedPreview.thumbURL`.

- [ ] **Step 2: Render inline thumbnail in the preview row**

Find the `previewContent` view (line 944+). Wrap the existing `Text(...)` in an `HStack` with the thumbnail:

```swift
@ViewBuilder
private var previewContent: some View {
    HStack(spacing: 6) {
        if let url = formattedPreview.thumbURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.systemGray5)
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }

        // Existing branches inside the original previewContent — system / outgoing / group / DM —
        // keep them as-is, just inside this HStack now.
        if isLastMessageSystem {
            Text(systemPreviewText)
                .font(.subheadline)
                .foregroundStyle(isActive ? secondaryTextColor : Color(.systemGray2))
                .lineLimit(1)
        } else if conversation.isGroup && isOutgoing {
            Text(previewAttributed).font(.subheadline).lineLimit(1)
        } else if conversation.isGroup {
            Text(previewAttributed).font(.subheadline).lineLimit(1)
        } else {
            Text(previewAttributed).font(.subheadline).lineLimit(1)
        }
    }
}
```

(Preserve any other styling that the original `previewContent` had — this snippet shows the structural change.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the simulator and visually verify the chat list**

```bash
xcrun simctl boot 'iPhone 17' 2>/dev/null
xcrun simctl launch booted chat.git
```

Send (or simulate) representative messages: a text-only DM, an image-only DM, an image-with-caption DM, a forwarded text DM, a forwarded image DM, a group text, a group forward. Verify each row matches the spec's table.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat(chat-list): inline thumbnail + compact preview (refs #129)"
```

---

## Task 4: Final verification

- [ ] **Step 1: Run full unit test suite**

```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests
```

Expected: green.

- [ ] **Step 2: UI smoke**

Capture a screenshot of the chat list with the variants from Task 3 Step 4. Attach to issue #129's PR description.

- [ ] **Step 3: Confirm branch state**

```bash
git log --oneline feat/compact-message-preview
```

Expected: spec commit + 3 feature commits (formatter, NSE, chat list). Push when ready (per `feedback_push_approval`, ask the user before pushing).

---

## Out of scope

- Chat-thread bubble forward header — covered by `2026-04-29-telegram-style-forward-header.md`.
- Long-press → in-app expanded preview — Spec 2 (separate Notification Content Extension target).
- Backend payload shape change — see `gitchat-webapp/docs/superpowers/plans/2026-05-08-compact-message-preview-webapp.md`.
- Extension UI rendering — see `gitchat_extension/docs/superpowers/plans/2026-05-08-compact-message-preview-ext.md`.

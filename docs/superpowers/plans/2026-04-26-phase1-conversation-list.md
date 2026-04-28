# Phase 1: Conversation List — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the conversation list to match Telegram iOS UX — avatars, checkmarks, drafts, mentions, unread polish, swipe actions, pagination, accessibility.

**Architecture:** Incremental refactor of `ConversationsListView.swift` and supporting files. Each task produces a working, buildable state. No new dependencies. Typing feature deferred (pending BE).

**Tech Stack:** SwiftUI, Combine (for DraftStore), UserDefaults, MessageCache, SocketClient

**Spec:** `docs/superpowers/specs/2026-04-25-telegram-clone-phase1-conversation-list.md` (Rev 2)

**Design System:** `docs/design/DESIGN.md` — semantic fonts, semantic colors, 4/8pt spacing grid

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `GitchatIOS/Core/Models/Models.swift` | Modify | Add `Conversation.withLastMessage()` helper |
| `GitchatIOS/Features/Conversations/ConversationsListView.swift` | Modify (major) | ConversationRow refactor, avatar, layout, checkmarks, draft, mentions, swipe actions, pagination, accessibility |
| `GitchatIOS/Features/Conversations/DraftStore.swift` | Create | Reactive draft state from UserDefaults |
| `GitchatIOS/Core/UI/GroupAvatarView.swift` | Create | Rounded-square group avatar with gradient fallback |

---

## Task 1: Conversation.withLastMessage() Helper

Eliminate the fragile 17-positional-argument reconstruction in `applyIncomingMessage`.

**Files:**
- Modify: `GitchatIOS/Core/Models/Models.swift:30-78`
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:33-59`

- [ ] **Step 1: Add withLastMessage helper to Conversation**

In `Models.swift`, after the `displayAvatarURL` computed property (line 77), add:

```swift
func withLastMessage(_ msg: Message, preview: String? = nil) -> Conversation {
    Conversation(
        id: id,
        type: type,
        is_group: is_group,
        group_name: group_name,
        group_avatar_url: group_avatar_url,
        repo_full_name: repo_full_name,
        participants: participants,
        other_user: other_user,
        last_message: msg,
        last_message_preview: preview ?? (msg.content.isEmpty ? last_message_preview : msg.content),
        last_message_text: msg.content.isEmpty ? last_message_text : msg.content,
        last_message_at: msg.created_at ?? last_message_at,
        unread_count: unread_count,
        pinned: pinned,
        pinned_at: pinned_at,
        is_request: is_request,
        updated_at: updated_at,
        is_muted: is_muted
    )
}
```

- [ ] **Step 2: Replace applyIncomingMessage reconstruction**

In `ConversationsListView.swift`, replace lines 37-57 (`let preview = ...` through the `Conversation(` init) with:

```swift
let preview = msg.content.isEmpty ? c.last_message_preview : msg.content
conversations[idx] = c.withLastMessage(msg, preview: preview)
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Core/Models/Models.swift GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "refactor: add Conversation.withLastMessage() helper to replace 17-arg reconstruction"
```

---

## Task 2: Group Avatar — Rounded Square with Gradient Fallback

Replace `GroupAvatarCluster` (stacked circles) with a single rounded-square avatar.

**Files:**
- Create: `GitchatIOS/Core/UI/GroupAvatarView.swift`
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:674-678, 761-791, 926-930`

- [ ] **Step 1: Create GroupAvatarView**

Create `GitchatIOS/Core/UI/GroupAvatarView.swift`:

```swift
import SwiftUI

/// Single rounded-square avatar for group conversations.
/// Shows group_avatar_url if available, otherwise first letter on gradient background.
struct GroupAvatarView: View {
    let name: String?
    let avatarURL: String?
    let groupId: String
    let size: CGFloat

    private static let gradients: [(Color, Color)] = [
        (Color(red: 1.0, green: 0.53, blue: 0.37), Color(red: 1.0, green: 0.32, blue: 0.42)),
        (Color(red: 1.0, green: 0.82, blue: 0.34), Color(red: 1.0, green: 0.62, blue: 0.18)),
        (Color(red: 0.55, green: 0.86, blue: 0.51), Color(red: 0.24, green: 0.78, blue: 0.40)),
        (Color(red: 0.38, green: 0.83, blue: 0.89), Color(red: 0.24, green: 0.63, blue: 0.90)),
        (Color(red: 0.44, green: 0.70, blue: 0.94), Color(red: 0.36, green: 0.56, blue: 0.94)),
        (Color(red: 0.83, green: 0.54, blue: 0.90), Color(red: 0.72, green: 0.42, blue: 0.84)),
        (Color(red: 0.94, green: 0.52, blue: 0.61), Color(red: 0.90, green: 0.41, blue: 0.60)),
    ]

    private var gradient: (Color, Color) {
        let idx = abs(groupId.hashValue) % Self.gradients.count
        return Self.gradients[idx]
    }

    private var initial: String {
        guard let name, let first = name.first else { return "#" }
        return String(first).uppercased()
    }

    private var cornerRadius: CGFloat { size * (16.0 / 56.0) }

    var body: some View {
        if let avatarURL, let url = URL(string: avatarURL) {
            CachedAsyncImage(url: url, contentMode: .fill, maxPixelSize: size * 3)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            let g = gradient
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [g.0, g.1], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Text(initial)
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }
}
```

> Note: `CachedAvatarImage` is `private` in ConversationsListView.swift — we need `CachedAsyncImage` which is already used elsewhere (line 709). If the cached image component is private, we'll use `AsyncImage` with the same URL and move on. Check at implementation time.

- [ ] **Step 2: Replace GroupAvatarCluster usage in ConversationRow**

In `ConversationsListView.swift`, replace the group avatar block (lines 674-678):

```swift
// OLD:
if conversation.isGroup && !conversation.participantsOrEmpty.isEmpty {
    GroupAvatarCluster(
        participants: Array(conversation.participantsOrEmpty.prefix(3)),
        size: avatarSize
    )

// NEW:
if conversation.isGroup {
    GroupAvatarView(
        name: conversation.group_name ?? conversation.displayTitle,
        avatarURL: conversation.group_avatar_url,
        groupId: conversation.id,
        size: avatarSize
    )
```

- [ ] **Step 3: Replace GroupAvatarCluster in ConversationHoldPreview**

In `ConversationsListView.swift`, replace the group avatar block in `header` (lines 926-930):

```swift
// OLD:
if conversation.isGroup && !conversation.participantsOrEmpty.isEmpty {
    GroupAvatarCluster(
        participants: Array(conversation.participantsOrEmpty.prefix(3)),
        size: 36
    )

// NEW:
if conversation.isGroup {
    GroupAvatarView(
        name: conversation.group_name ?? conversation.displayTitle,
        avatarURL: conversation.group_avatar_url,
        groupId: conversation.id,
        size: 36
    )
```

- [ ] **Step 4: Remove GroupAvatarCluster struct**

Delete `GroupAvatarCluster` (lines 761-791). It's no longer used.

- [ ] **Step 5: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Core/UI/GroupAvatarView.swift GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: replace GroupAvatarCluster with rounded-square GroupAvatarView + gradient fallback"
```

---

## Task 3: Avatar Size + Row Layout + Typography (DESIGN.md Compliance)

Update avatar size from 50pt to 56pt, fix typography to use semantic fonts, fix spacing to 4/8pt grid.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:601-757`

- [ ] **Step 1: Update avatarSize**

Change the iOS return value (line 619) from `50` to `56`:

```swift
// OLD: return 50
// NEW: return 56
```

- [ ] **Step 2: Update row padding**

Change iOS row padding (line 754) from `4` to `12`:

```swift
// OLD: .padding(.vertical, 4)
// NEW: .padding(.vertical, 12)
```

Also update `listRowInsets` (line 442) from `top: 6, bottom: 6` to `top: 0, bottom: 0` (padding handled by the row itself now):

```swift
// OLD: .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
// NEW: .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
```

- [ ] **Step 3: Update typography — title**

Change title font (line 689) to differentiate read/unread:

```swift
// OLD:
.font(.headline)

// NEW:
.font(displayedUnread > 0 ? .headline : .body)
```

This requires `ConversationRow` to know `displayedUnread`. It already has this as a computed property (line 631).

Wait — `displayedUnread` is already a computed property on `ConversationRow`. But the title is inside the row body, so we can use it directly. Good.

- [ ] **Step 4: Update typography — timestamp**

Change `metaFont` for iOS (line 627) from `.caption2` to `.footnote`:

```swift
// OLD: return .caption2
// NEW: return .footnote
```

- [ ] **Step 5: Update timestamp color — accent when unread**

Change timestamp color (line 727) to reflect unread state:

```swift
// OLD:
.foregroundStyle(secondaryTextColor)

// NEW:
.foregroundStyle(displayedUnread > 0 && !isActive ? Color("AccentColor") : secondaryTextColor)
```

- [ ] **Step 6: Update unread badge styling**

Change badge font (line 732) from `.caption2.bold()` to `.footnote.bold()`:

```swift
// OLD: .font(.caption2.bold())
// NEW: .font(.footnote.bold())
```

Change the minimum badge size — add `.frame(minWidth: 24, minHeight: 24)` before `.background`:

```swift
Text("\(displayedUnread)")
    .font(.footnote.bold())
    .padding(.horizontal, 8).padding(.vertical, 2)
    .frame(minWidth: 24, minHeight: 24)
    .background(...)
```

- [ ] **Step 7: Update skeleton avatar size**

Change skeleton loading state (line 475) from `50` to `56`:

```swift
// OLD: SkeletonList(count: 10, avatarSize: 50)
// NEW: SkeletonList(count: 10, avatarSize: 56)
```

- [ ] **Step 8: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: update conversation list layout — 56pt avatars, semantic fonts, 4/8pt grid spacing"
```

---

## Task 4: Delivery Checkmarks

Add sent/read/sending/failed checkmark states to conversation rows.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationRow right column)

- [ ] **Step 1: Add checkmark computed properties to ConversationRow**

Add after `displayedUnread` (line 633):

```swift
private var isOutgoing: Bool {
    guard let sender = conversation.last_message?.sender else { return false }
    return sender == AuthStore.shared.login
}

private var checkmarkState: CheckmarkState {
    guard isOutgoing, let msg = conversation.last_message else { return .none }
    if msg.unsent_at != nil { return .failed }
    if msg.id.hasPrefix("local-") { return .sending }
    // Check if read
    if let cache = MessageCache.shared.get(conversation.id),
       let createdAt = msg.created_at {
        if conversation.isGroup {
            if let cursors = cache.readCursors {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoFallback = ISO8601DateFormatter()
                isoFallback.formatOptions = [.withInternetDateTime]
                func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoFallback.date(from: s) }
                if let msgDate = parseDate(createdAt) {
                    let otherRead = cursors.contains { login, readAt in
                        guard login != AuthStore.shared.login,
                              let cursorDate = parseDate(readAt) else { return false }
                        return cursorDate >= msgDate
                    }
                    if otherRead { return .read }
                }
            }
        } else if let otherReadAt = cache.otherReadAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            if let readDate = (iso.date(from: otherReadAt) ?? isoFallback.date(from: otherReadAt)),
               let msgDate = (iso.date(from: createdAt) ?? isoFallback.date(from: createdAt)),
               readDate >= msgDate {
            return .read
        }
    }
    return .sent
}

private enum CheckmarkState {
    case none, sending, sent, read, failed
}
```

- [ ] **Step 2: Add checkmark view to right column**

In the right column VStack (line 724), replace the timestamp line with:

```swift
HStack(spacing: 4) {
    switch checkmarkState {
    case .sending:
        Image(systemName: "clock")
            .font(.system(size: 12))
            .foregroundStyle(Color(.systemGray))
            .accessibilityLabel("Sending")
    case .sent:
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(.systemGray))
            .accessibilityLabel("Sent")
    case .read:
        ZStack {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .offset(x: 4)
        }
        .foregroundStyle(Color("AccentColor"))
        .accessibilityLabel("Read")
    case .failed:
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(Color(.systemRed))
            .accessibilityLabel("Failed to send")
    case .none:
        EmptyView()
    }
    Text(RelativeTime.chatListStamp(conversation.last_message_at))
        .font(metaFont)
        .foregroundStyle(displayedUnread > 0 && !isActive ? Color("AccentColor") : secondaryTextColor)
        .instantTooltip(ChatMessageText.fullTimestamp(conversation.last_message_at))
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: add delivery checkmarks (sending/sent/read/failed) to conversation list"
```

---

## Task 5: DraftStore + Draft Indicator

Create reactive DraftStore and show "Draft:" prefix in conversation rows.

**Files:**
- Create: `GitchatIOS/Features/Conversations/DraftStore.swift`
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationRow preview)

- [ ] **Step 1: Create DraftStore**

Create `GitchatIOS/Features/Conversations/DraftStore.swift`:

```swift
import SwiftUI
import Combine

@MainActor
final class DraftStore: ObservableObject {
    static let shared = DraftStore()
    static let draftChangedNotification = Notification.Name("gitchatDraftChanged")

    private var drafts: [String: String] = [:]
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = NotificationCenter.default
            .publisher(for: Self.draftChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let convoId = note.userInfo?["conversationId"] as? String else { return }
                self?.reload(convoId)
            }
    }

    func draft(for conversationId: String) -> String? {
        if let cached = drafts[conversationId] { return cached.isEmpty ? nil : cached }
        let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversationId)") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[conversationId] = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private func reload(_ conversationId: String) {
        let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversationId)") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = drafts[conversationId]
        drafts[conversationId] = trimmed
        if old != trimmed { objectWillChange.send() }
    }

    func loadAll(for conversationIds: [String]) {
        for id in conversationIds {
            let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(id)") ?? ""
            drafts[id] = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
```

- [ ] **Step 2: Post draft notification from ChatViewModel**

In `ChatViewModel.swift` where draft is saved (the `saveDraft()` method), add the notification post **at the end of the method, outside the if/else branches** — so it fires for both setting and clearing a draft:

```swift
func saveDraft() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        UserDefaults.standard.removeObject(forKey: "gitchat.draft.\(conversation.id)")
    } else {
        UserDefaults.standard.set(draft, forKey: "gitchat.draft.\(conversation.id)")
    }
    // Notify DraftStore — must fire for both set and clear
    NotificationCenter.default.post(
        name: DraftStore.draftChangedNotification,
        object: nil,
        userInfo: ["conversationId": conversation.id]
    )
}
```

- [ ] **Step 3: Add draft indicator to ConversationRow**

In `ConversationRow`, add `@ObservedObject private var draftStore = DraftStore.shared`.

Replace the preview text area (lines 707-721) with draft-aware logic:

```swift
HStack(alignment: .top, spacing: 6) {
    if let draft = draftStore.draft(for: conversation.id) {
        Text("Draft: ").foregroundStyle(Color(.systemRed)).font(.subheadline)
        + Text(draft).foregroundStyle(secondaryTextColor).font(.subheadline)
    } else {
        if let thumbURL = lastPhotoURL {
            CachedAsyncImage(
                url: thumbURL,
                contentMode: .fill,
                maxPixelSize: 80
            )
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        previewContent
    }
}
.lineLimit(2)
```

And add a `previewContent` computed property:

```swift
@ViewBuilder
private var previewContent: some View {
    if let msg = conversation.last_message, (msg.type ?? "user") != "user" {
        // System message — italic
        Text(previewWithoutPhotoEmoji)
            .font(.subheadline.italic())
            .foregroundStyle(Color(.systemGray2))
    } else if conversation.isGroup, isOutgoing, conversation.last_message != nil {
        // Group outgoing — "You:" prefix
        Text("You: ").foregroundStyle(Color("AccentColor")).font(.subheadline)
        + Text(previewWithoutPhotoEmoji).foregroundStyle(secondaryTextColor).font(.subheadline)
    } else {
        Text(previewWithoutPhotoEmoji)
            .font(.subheadline)
            .foregroundStyle(secondaryTextColor)
    }
}
```

- [ ] **Step 4: Load drafts on list appear**

In `ConversationsListView`, after `vm.load()` in `.task` (line 532), add:

```swift
DraftStore.shared.loadAll(for: vm.conversations.map(\.id))
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/DraftStore.swift GitchatIOS/Features/Conversations/ConversationsListView.swift GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift
git commit -m "feat: add DraftStore and draft indicator in conversation list"
```

---

## Task 6: "You:" Prefix + Sender Name + System Message Italic

This is largely handled by the `previewContent` computed property in Task 5. This task adds the sender avatar for group incoming messages.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationRow)

- [ ] **Step 1: Add sender mini-avatar for group incoming**

Update the sender name line (lines 701-706) to include a mini avatar:

```swift
if let sender = lastSenderLogin, !isOutgoing {
    HStack(spacing: 4) {
        if let avatarURL = conversation.last_message?.sender_avatar,
           let url = URL(string: avatarURL) {
            CachedAsyncImage(
                url: url,
                contentMode: .fill,
                maxPixelSize: 60
            )
            .frame(width: 20, height: 20)
            .clipShape(Circle())
        } else {
            // Fallback: initial letter on gray circle
            Circle()
                .fill(Color(.systemGray4))
                .frame(width: 20, height: 20)
                .overlay {
                    Text(String(sender.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        Text(sender)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(secondaryTextColor)
            .lineLimit(1)
    }
} else if isOutgoing && conversation.isGroup {
    // "You:" is shown in previewContent, no separate sender line needed
    EmptyView()
}
```

- [ ] **Step 2: Ensure system messages don't show sender**

The `lastSenderLogin` computed property (line 650-657) already filters `type == nil || type == "user"`. System messages return nil, so no sender line appears. Verify this is correct.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: add sender avatar for group incoming + system message italic"
```

---

## Task 7: Mention Badge + Right Column Polish

Add @ mention badge and clean up pin/mute indicator placement in the right column.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationRow right column)

- [ ] **Step 1: Add mention detection computed property**

Add to `ConversationRow`:

```swift
private var hasMention: Bool {
    guard displayedUnread > 0,
          conversation.isGroup,
          let content = conversation.last_message?.content,
          let login = AuthStore.shared.login else { return false }
    let pattern = "(?<![\\w])@\(NSRegularExpression.escapedPattern(for: login))(?![\\w])"
    return content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}
```

- [ ] **Step 2: Update right column bottom section**

In the right column VStack, replace the unread badge block (lines 729-747) with:

```swift
HStack(spacing: 4) {
    if displayedUnread > 0 {
        if hasMention {
            Text("@")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color("AccentColor"), in: Circle())
                .foregroundStyle(.white)
                .accessibilityLabel("You were mentioned")
        }
        Text("\(displayedUnread)")
            .font(.footnote.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(minWidth: 24, minHeight: 24)
            .background(
                isActive
                    ? Color.white
                    : (isMuted ? Color(.systemGray) : Color("AccentColor")),
                in: .capsule
            )
            .foregroundStyle(
                isActive
                    ? Color("AccentColor")
                    : (isMuted ? .white : .white)
            )
        if isMuted {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(secondaryTextColor)
        }
    } else if conversation.isPinned {
        Image(systemName: "pin.fill")
            .font(.system(size: 12))
            .foregroundStyle(secondaryTextColor)
            .accessibilityLabel("Pinned")
        if isMuted {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(secondaryTextColor)
                .accessibilityLabel("Muted")
        }
    } else {
        Color.clear.frame(width: 1, height: 24)
    }
}
```

- [ ] **Step 3: Move pin/mute icons from title line to right column**

Remove pin and mute icons from the title HStack (lines 692-699) since they're now in the right column bottom section:

```swift
// REMOVE these from the title HStack:
// if conversation.isPinned { Image(systemName: "pin.fill")... }
// if isMuted { Image(systemName: "bell.slash.fill")... }
```

The title HStack simplifies to just:

```swift
HStack(spacing: 6) {
    Text(conversation.displayTitle)
        .font(displayedUnread > 0 ? .headline : .body)
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: add mention badge, move pin/mute to right column, update badge styling"
```

---

## Task 8: Swipe Actions Polish

Update swipe action colors to match Telegram and add Read/Unread toggle.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:447-469`
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationsViewModel)

- [ ] **Step 1: Add toggleRead to ConversationsViewModel**

Add after `markLocallyRead` method:

```swift
func toggleRead(_ convo: Conversation) {
    if locallyRead.contains(convo.id) {
        locallyRead.remove(convo.id)
    } else {
        locallyRead.insert(convo.id)
    }
}
```

- [ ] **Step 2: Update swipe actions**

Replace the swipe actions block (lines 447-469):

```swift
.swipeActions(edge: .leading, allowsFullSwipe: true) {
    Button {
        vm.toggleRead(convo)
    } label: {
        Label(
            vm.locallyRead.contains(convo.id) || convo.unreadCount == 0 ? "Unread" : "Read",
            systemImage: vm.locallyRead.contains(convo.id) || convo.unreadCount == 0 ? "envelope.badge.fill" : "envelope.open.fill"
        )
    }
    .tint(Color(.systemGreen))
}
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    Button(role: .destructive) {
        confirmDelete = convo
    } label: {
        Label("Delete", systemImage: "trash")
    }
    .tint(.red)
    Button {
        Task { await vm.toggleMute(convo) }
    } label: {
        let muted = vm.isLocallyMuted(convo)
        Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell.fill" : "bell.slash.fill")
    }
    .tint(.orange)
    Button {
        Task { await vm.togglePin(convo) }
    } label: {
        Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash.fill" : "pin.fill")
    }
    .tint(Color(.systemBlue))
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: add read/unread swipe action, reorder and recolor swipe buttons"
```

---

## Task 9: Pagination

Add cursor-based pagination with load cancellation.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ViewModel + List)

- [ ] **Step 1: Add pagination state to ConversationsViewModel**

Add to the @Published properties (after line 14):

```swift
@Published var isLoadingMore = false
private var nextCursor: String?
private var loadTask: Task<Void, Never>?
```

- [ ] **Step 2: Refactor load() with cancellation**

Replace the `load()` method (lines 182-211):

```swift
func load(reset: Bool = true) async {
    loadTask?.cancel()
    let task = Task { @MainActor in
        if reset {
            if conversations.isEmpty { isLoading = true }
            isSyncing = true
        }
        let started = Date()
        defer {
            if reset { isLoading = false }
        }
        do {
            let cursor = reset ? nil : nextCursor
            let resp = try await APIClient.shared.listConversations(cursor: cursor)
            guard !Task.isCancelled else { return }

            if reset {
                let deduped = Self.dedupeChannels(resp.conversations)
                self.conversations = deduped
                self.locallyRead.removeAll()
                // Keep locallyMuted/locallyUnmuted — syncMutedStore() reconciles them
            } else {
                // Merge new page, dedupe by id
                let existingIds = Set(conversations.map(\.id))
                let newConvos = resp.conversations.filter { !existingIds.contains($0.id) }
                let merged = conversations + newConvos
                self.conversations = Self.dedupeChannels(merged)
            }

            self.nextCursor = resp.nextCursor
            ConversationsCache.shared.store(conversations)
            syncMutedStore()
            for convo in resp.conversations {
                MessageCache.shared.prefetch(conversationId: convo.id)
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
        if reset {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 2 {
                try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
            }
            isSyncing = false
        }
        isLoadingMore = false
    }
    loadTask = task
    await task.value
}

func loadMoreIfNeeded(current: Conversation) {
    guard !isLoadingMore, nextCursor != nil else { return }
    let thresholdIndex = conversations.index(conversations.endIndex, offsetBy: -5, limitedBy: conversations.startIndex) ?? conversations.startIndex
    if let currentIndex = conversations.firstIndex(where: { $0.id == current.id }),
       currentIndex >= thresholdIndex {
        isLoadingMore = true
        Task { await load(reset: false) }
    }
}
```

- [ ] **Step 3: Add loadMoreIfNeeded trigger to list rows**

In the `conversationListRow` function, add `.onAppear` to trigger pagination:

```swift
// Add after .swipeActions block:
.onAppear {
    vm.loadMoreIfNeeded(current: convo)
}
```

- [ ] **Step 4: Add loading indicator at bottom of list**

In the `List` block (line 489), after the `ForEach`/list content, add:

```swift
if vm.isLoadingMore {
    HStack {
        Spacer()
        ProgressView()
            .accessibilityLabel("Loading more conversations")
        Spacer()
    }
    .listRowSeparator(.hidden)
}
```

Wait — the current code uses `List(filtered)` directly (line 489), not `List { ForEach }`. We need to restructure to add the loading indicator. Change to:

```swift
List {
    ForEach(filtered) { convo in
        conversationListRow(convo)
            .hideMacScrollIndicators()
    }
    if vm.isLoadingMore {
        HStack {
            Spacer()
            ProgressView()
                .accessibilityLabel("Loading more conversations")
            Spacer()
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
```

- [ ] **Step 5: Disable animation for pagination appends**

The `.animation(.spring(...), value: conversations.map(\.id))` on line 497 will cause frame drops during pagination. Remove it or conditionalize:

```swift
// Replace the animation line with:
.animation(vm.isLoadingMore ? .none : .spring(response: 0.45, dampingFraction: 0.82), value: vm.conversations.map(\.id))
```

- [ ] **Step 6: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: add cursor-based pagination with load cancellation and dedup"
```

---

## Task 10: Accessibility Labels

Add VoiceOver support to all visual-only elements.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` (ConversationRow)

- [ ] **Step 1: Add composed accessibility label to ConversationRow**

Add at the end of the ConversationRow `body` (before the closing `}` of HStack, around line 748):

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(accessibilityRowLabel)
```

And add the computed property:

```swift
private var accessibilityRowLabel: String {
    var parts: [String] = []
    parts.append(conversation.displayTitle)

    // Online status
    if let login = conversation.other_user?.login,
       PresenceStore.shared.isOnline(login) {
        parts.append("online")
    }

    // Draft / Preview
    if let draft = DraftStore.shared.draft(for: conversation.id) {
        parts.append("Draft: \(draft)")
    } else {
        let preview = conversation.previewText ?? ""
        if !preview.isEmpty { parts.append(preview) }
    }

    // Checkmark
    switch checkmarkState {
    case .sending: parts.append("Sending")
    case .sent: parts.append("Sent")
    case .read: parts.append("Read")
    case .failed: parts.append("Failed to send")
    case .none: break
    }

    // Unread
    if displayedUnread > 0 {
        parts.append("\(displayedUnread) unread message\(displayedUnread == 1 ? "" : "s")")
    }
    if hasMention { parts.append("You were mentioned") }
    if isMuted { parts.append("Muted") }
    if conversation.isPinned { parts.append("Pinned") }

    return parts.joined(separator: ". ")
}
```

- [ ] **Step 2: Mark avatar as decorative**

In `AvatarView` and `GroupAvatarView`, the avatar image is decorative (name is read from title). Add `.accessibilityHidden(true)` to the outer frame of both views.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift GitchatIOS/Core/UI/GroupAvatarView.swift
git commit -m "feat: add VoiceOver accessibility labels to conversation rows"
```

---

## Task 11: Row Tap Animation Fix + Online Dot Polish

Fix tap animation to Telegram-style (background highlight, not scale) and polish online dot sizing.

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift`

- [ ] **Step 1: Replace tap scale effect with background highlight**

Remove the scale/opacity tap animation (lines 444-445):

```swift
// REMOVE:
.scaleEffect(tappedConvoId == convo.id ? 0.97 : 1)
.opacity(tappedConvoId == convo.id ? 0.7 : 1)
```

The row background function `rowBackground(for:)` already handles active state. The tap feedback is already handled by the 0.12s `tappedConvoId` state which we can keep for a subtle opacity-only effect if desired, or remove entirely for pure Telegram feel. Remove both lines.

- [ ] **Step 2: Update online dot sizing**

In `AvatarView` (line 805-809), update the dot calculation:

```swift
// OLD:
let dot = max(8, size * 0.28)

// NEW:
let dot: CGFloat = 12
```

Update the border and color:

```swift
// OLD:
Circle()
    .fill(Color.green)
    ...
    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(1, dot * 0.18)))

// NEW:
Circle()
    .fill(Color(.systemGreen))  // semantic green, adapts to dark mode
    ...
    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift
git commit -m "feat: fix tap animation to Telegram-style, polish online dot sizing"
```

---

## Task 12: Final Build + Integration Verify

**Files:** None — verification only.

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build 2>&1 | tail -10
```

- [ ] **Step 2: Verify Mac Catalyst build**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -10
```

- [ ] **Step 3: Commit all remaining changes if any**

```bash
git status
# If clean, no commit needed
```

---

## Summary

| Task | Feature | Est |
|------|---------|-----|
| 1 | Conversation.withLastMessage() helper | 5 min |
| 2 | GroupAvatarView (rounded square + gradient) | 15 min |
| 3 | Avatar 56pt + layout + typography | 15 min |
| 4 | Delivery checkmarks | 20 min |
| 5 | DraftStore + draft indicator + preview refactor | 25 min |
| 6 | Sender avatar + system italic | 10 min |
| 7 | Mention badge + right column polish | 20 min |
| 8 | Swipe actions polish | 10 min |
| 9 | Pagination with cancellation | 25 min |
| 10 | Accessibility labels | 15 min |
| 11 | Tap animation + online dot | 5 min |
| 12 | Final build verification | 5 min |
| **Total** | | **~3 hours coding** |

Buffer for debugging build issues, merge conflicts between tasks, and runtime testing: **+1-2 hours**. Total: **~4-5 hours for one session**.

---

## Explicitly Deferred (out of scope for this plan)

These spec features are acknowledged but deferred to a follow-up task:

| Feature | Reason |
|---------|--------|
| **Typing in List** | Pending BE confirmation on `subscribe:user` typing forwarding |
| **Rich Message Preview Types** | Existing `previewText` covers basic cases; mapping Photo/Video/File prefixes is polish work |
| **Connection Status Banner** | Requires new UI component + socket state observation; medium effort, low priority vs core list features |
| **Separator inset 84pt** | Minor visual — can be added as `.alignmentGuide(.listRowSeparatorLeading) { _ in 84 }` in a polish pass |
| **`@ScaledMetric` for fixed sizes** | Semantic fonts handle most Dynamic Type; badge/icon scaling is polish |
| **`applyLocalMetadata` refactor** | Same 17-arg fragility as `applyIncomingMessage` — add `withMetadata()` helper in follow-up |

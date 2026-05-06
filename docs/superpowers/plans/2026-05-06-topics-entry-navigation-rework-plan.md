# Topics Entry & Navigation Rework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Topics' duplicate entry surfaces (popover + tab strip on Catalyst, bottom sheet on iOS) with a Telegram Forum-style sidebar swap on Catalyst and a direct push navigation on iOS, twinning `TopicRow`'s visual quality to `ConversationRow`.

**Architecture:** Catalyst sidebar wraps `ConversationsListView` in a `NavigationStack` keyed off `AppRouter.topicSidebarPath`. Clicking a topic-enabled group pushes `TopicListSidebarView` and auto-resolves a default topic into `AppRouter.selectedTopic`, which the detail panel renders. iOS uses native `NavigationStack` push from `ConversationsListView` → `TopicListPushView` → `ChatDetailView(.topic)`.

**Tech Stack:** SwiftUI (iOS 16+ minimum; iOS 17 features behind `#available`), `NavigationStack`, `NavigationSplitView`, XcodeGen for project generation.

**Spec:** `docs/superpowers/specs/2026-05-06-topics-entry-navigation-rework-design.md`

**Project conventions** (from `CLAUDE.md`):
- No XCTest target — verification is `xcodebuild` clean compile + manual scenarios on a booted simulator.
- No `print()` for app logging — use `NSLog`.
- After adding/removing/renaming Swift files, **always** run `xcodegen generate` and verify file presence in `project.pbxproj` via `grep -c`.

**Build commands used throughout:**

```bash
# Regenerate Xcode project (after add/remove/rename of .swift files)
xcodegen generate

# iOS Simulator compile gate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20

# Mac Catalyst compile gate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both compile gates must pass with `BUILD SUCCEEDED`.

---

## Task 0: Branch setup

**Files:** none (git operations only)

- [ ] **Step 1: Create new branch from current `hiru-desktop-polish`**

```bash
git checkout -b hiru-topics-rework-entry
git status
```

Expected: clean working tree on new branch `hiru-topics-rework-entry`.

- [ ] **Step 2: Verify spec is committed and reachable**

```bash
ls docs/superpowers/specs/2026-05-06-topics-entry-navigation-rework-design.md
git log --oneline -1 -- docs/superpowers/specs/2026-05-06-topics-entry-navigation-rework-design.md
```

Expected: file exists; commit hash printed.

---

## Task 1: Extend `AppRouter` with topic-mode state

**Files:**
- Modify: `GitchatIOS/Core/UI/AppRouter.swift`

This task adds router state that no other code depends on yet — safe to land standalone.

- [ ] **Step 1: Add `TopicSidebarRoute` and `TopicTarget` types at the top of the file**

Insert after the `import SwiftUI` line:

```swift
import SwiftUI

/// Sidebar `NavigationStack` route used on Mac Catalyst when the user
/// enters topic mode for a parent group conversation.
struct TopicSidebarRoute: Hashable {
    let parent: Conversation
}

/// Active topic target. Wraps the (topic, parent) pair so SwiftUI can
/// diff the detail panel cleanly.
struct TopicTarget: Equatable {
    let topic: Topic
    let parent: Conversation
}
```

- [ ] **Step 2: Add new `@Published` properties and `activeTopicByParent` dict to `AppRouter`**

In `AppRouter`, just below the existing `@Published var pendingInviteCode: String?` line, add:

```swift
    /// Catalyst sidebar `NavigationStack` path. Empty = chats list shown.
    /// One element = topic list pushed for that parent.
    @Published var topicSidebarPath: NavigationPath = NavigationPath()

    /// What the Catalyst detail panel renders while the user is in topic
    /// mode. `nil` = fall back to placeholder / `selectedConversation`.
    @Published var selectedTopic: TopicTarget? = nil {
        didSet {
            // Picking a topic clears any sticky chat / profile preview so
            // the detail panel actually displays the topic chat.
            if selectedTopic != nil {
                selectedConversation = nil
                selectedProfile = nil
            }
        }
    }

    /// In-memory dict of last-picked topic per parent for the current
    /// session. Not persisted across launches.
    private(set) var activeTopicByParent: [String: String] = [:]
```

- [ ] **Step 3: Add `enterTopicMode`, `pickTopic`, `exitTopicMode`, `resolveActiveTopic` helpers**

At the end of `AppRouter` (before the closing `}` of the class), add:

```swift
    /// Pushes the topic list onto the Catalyst sidebar stack and resolves
    /// a default active topic. Call from row tap on a topic-enabled group.
    func enterTopicMode(parent: Conversation) {
        topicSidebarPath.append(TopicSidebarRoute(parent: parent))
        if let resolved = resolveActiveTopic(parent: parent) {
            selectedTopic = TopicTarget(topic: resolved, parent: parent)
        } else {
            selectedTopic = nil   // empty list — detail panel shows placeholder
        }
    }

    /// Records and renders the user's pick. Idempotent.
    func pickTopic(_ topic: Topic, in parent: Conversation) {
        activeTopicByParent[parent.id] = topic.id
        selectedTopic = TopicTarget(topic: topic, parent: parent)
    }

    /// Pops the sidebar back to the chats list and clears the active
    /// topic. Detail panel snaps to the placeholder.
    func exitTopicMode() {
        topicSidebarPath = NavigationPath()
        selectedTopic = nil
    }

    /// Returns the topic that should be rendered when entering topic mode.
    /// Order: previously-picked → general → first.
    private func resolveActiveTopic(parent: Conversation) -> Topic? {
        let topics = TopicListStore.shared.topics(forParent: parent.id)
        if let id = activeTopicByParent[parent.id],
           let t = topics.first(where: { $0.id == id }) {
            return t
        }
        if let general = topics.first(where: { $0.is_general }) {
            return general
        }
        return topics.first
    }
```

- [ ] **Step 4: Add tab-switch reset to `selectedTab.didSet`**

Find the existing `@Published var selectedTab: Int = 0 { didSet { ... } }` block and update it to also clear topic-mode state when the user leaves the Chats tab:

```swift
    @Published var selectedTab: Int = 0 {
        didSet {
            // Profile browsing is transient — clear it whenever the user
            // jumps to a different tab so the detail panel snaps back to
            // the sticky chat (or placeholder) for that context.
            if oldValue != selectedTab { selectedProfile = nil }
            // Topic mode is bound to the Chats tab. Leaving Chats resets
            // the topic sidebar stack so returning lands on chats list.
            if oldValue != selectedTab && oldValue == 0 {
                topicSidebarPath = NavigationPath()
                selectedTopic = nil
            }
        }
    }
```

- [ ] **Step 5: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both must say `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Core/UI/AppRouter.swift
git commit -m "feat(ios): topic-mode router state — sidebar path + active topic + helpers"
```

---

## Task 2: Overhaul `TopicRow` to twin `ConversationRow` visual

**Files:**
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicRow.swift`

This rewrites the row's body. No behavior change — same tap, same context menu — just visual.

- [ ] **Step 1: Replace the entire `TopicRow.swift` body with the twinned implementation**

Overwrite with:

```swift
import SwiftUI

struct TopicRow: View {
    let topic: Topic
    let isActive: Bool
    let isPinned: Bool
    let onTap: () -> Void

    init(topic: Topic, isActive: Bool, isPinned: Bool = false, onTap: @escaping () -> Void) {
        self.topic = topic
        self.isActive = isActive
        self.isPinned = isPinned
        self.onTap = onTap
    }

    @ScaledMetric(relativeTo: .caption) private var mentionBadgeSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var badgeMinSize: CGFloat = 18

    /// 44pt on Catalyst (Apple list standard), 64pt on iOS for the
    /// Telegram-feeling chat-list look — mirrors `ConversationRow`.
    private var iconSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 44
        #else
        return 64
        #endif
    }

    private var iconCornerRadius: CGFloat { iconSize * 0.25 }

    private var color: Color { TopicColorToken.resolve(topic.color_token).color }

    private var primaryTextColor: Color { isActive ? .white : .primary }
    private var secondaryTextColor: Color { isActive ? .white.opacity(0.85) : .secondary }
    private var tertiaryTextColor: Color { isActive ? .white.opacity(0.7) : .secondary }

    private var senderPreview: String? {
        guard let preview = topic.last_message_preview else { return nil }
        if let sender = topic.last_sender_login, !sender.isEmpty {
            return "\(sender): \(preview)"
        }
        return preview
    }

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name)
                    .font(.headline)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                if let preview = senderPreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let ts = topic.last_message_at {
                    Text(RelativeTime.chatListStamp(ts))
                        .font(.footnote)
                        .foregroundStyle(tertiaryTextColor)
                }
                badges
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(isActive ? Color("AccentColor") : .clear)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            #if !targetEnvironment(macCatalyst)
            Haptics.selection()
            #endif
            onTap()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
    }

    private var iconSquare: some View {
        Text(topic.displayEmoji)
            .font(.system(size: iconSize * 0.5))
            .frame(width: iconSize, height: iconSize)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: iconCornerRadius))
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if topic.unread_count > 0 {
                if topic.hasMention {
                    Text("@")
                        .font(.caption.bold())
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(badgeBG, in: Circle())
                        .foregroundStyle(badgeFG)
                }
                if topic.hasReaction {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(badgeBG, in: Circle())
                        .foregroundStyle(badgeFG)
                        .accessibilityLabel("reaction")
                }
                Text(topic.unread_count > 99 ? "99+" : "\(topic.unread_count)")
                    .font(.footnote.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(minWidth: badgeMinSize, minHeight: badgeMinSize)
                    .background(badgeBG, in: .capsule)
                    .foregroundStyle(badgeFG)
            }
        }
    }

    private var badgeBG: Color {
        isActive ? Color.white.opacity(0.25) : Color("AccentColor")
    }

    private var badgeFG: Color {
        isActive ? .white : .white
    }
}

#if DEBUG
extension Topic {
    static func fixturePreview(id: String, name: String, emoji: String?,
                                color: String? = "blue", unread: Int = 0,
                                mentions: Int = 0, reactions: Int = 0,
                                isPinned: Bool = false) -> Topic {
        Topic(id: id, parent_conversation_id: "p", name: name, icon_emoji: emoji,
              color_token: color, is_general: id == "g",
              pin_order: isPinned ? 1 : nil, archived_at: nil,
              last_message_at: "2026-04-28T10:00:00Z",
              last_message_preview: "preview text", last_sender_login: "alice",
              unread_count: unread, unread_mentions_count: mentions,
              unread_reactions_count: reactions,
              created_by: "alice", created_at: "2026-04-20T08:00:00Z")
    }
}

#Preview {
    VStack(spacing: 0) {
        TopicRow(topic: .fixturePreview(id: "g", name: "General", emoji: "💬",
                                         unread: 0, isPinned: true),
                 isActive: true, isPinned: true, onTap: {})
        TopicRow(topic: .fixturePreview(id: "b", name: "Bugs", emoji: "🐛",
                                         unread: 12, mentions: 1, isPinned: true),
                 isActive: false, isPinned: true, onTap: {})
        TopicRow(topic: .fixturePreview(id: "v", name: "v2.0", emoji: "🚀",
                                         color: "red", unread: 1),
                 isActive: false, isPinned: false, onTap: {})
    }
}
#endif
```

- [ ] **Step 2: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicRow.swift
git commit -m "feat(ios): TopicRow twin of ConversationRow — 44/64 icon, sender:preview, accent active"
```

---

## Task 3: Polish empty state + animate pin reorder in `TopicListContent`

**Files:**
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicListContent.swift`

- [ ] **Step 1: Replace the `emptyState` computed view**

Find the current `emptyState` (around lines 90-100) and replace its body with:

```swift
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color("AccentColor"))
            Text("Start a topic")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Topics keep group conversations organized by subject.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button {
                showCreate = true
            } label: {
                Label("New Topic", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
```

- [ ] **Step 2: Animate the `togglePin` callsite**

Find the existing `private func togglePin(_ t: Topic)` and update its body to wrap the store call in `withAnimation`:

```swift
    private func togglePin(_ t: Topic) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            store.togglePin(topicId: t.id, parentId: parent.id)
        }
    }
```

- [ ] **Step 3: Update the doc-comment at the top of the file**

Replace the existing top doc-comment (lines 3-4) with:

```swift
/// Cross-platform body for the topic list. Wrapped by
/// `TopicListSidebarView` (Mac Catalyst sidebar) and
/// `TopicListPushView` (iOS pushed view). Renders the section'd list
/// of topics with empty/loading/error variants.
```

- [ ] **Step 4: Apply 4pt section spacing on iOS 17+ to match `ConversationsListView`**

Find the `list` computed view (`private var list: some View { ... }`) and update the `.listStyle(.plain)` line to add the spacing modifier just after it:

```swift
    private var list: some View {
        List {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { row(for: $0) }
                }
            }
            Section("All topics") {
                ForEach(unpinned) { row(for: $0) }
            }
        }
        .listStyle(.plain)
        .modifier(TopicListSectionSpacing())
        .listRowSeparator(.hidden)
    }
```

Append the modifier definition at the bottom of `TopicListContent.swift` (outside the struct but in the same file):

```swift
private struct TopicListSectionSpacing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.listSectionSpacing(4)
        } else {
            content
        }
    }
}
```

- [ ] **Step 5: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`. (`TopicListSidebarView` / `TopicListPushView` are not yet defined — the doc-comment references them but is a comment, so it does not affect compile.)

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListContent.swift
git commit -m "feat(ios): polished empty state + spring pin reorder + 4pt section spacing"
```

---

## Task 4: Create `TopicListSidebarView` (Catalyst)

**Files:**
- Create: `GitchatIOS/Features/Conversations/Topics/TopicListSidebarView.swift`

- [ ] **Step 1: Create the file with full implementation**

```swift
#if targetEnvironment(macCatalyst)
import SwiftUI

/// Catalyst-only wrapper around `TopicListContent`. Renders the 2-line
/// sidebar header (back · group emoji · group name · "+" / "N members ·
/// M online") and the topic list body. Hosted via the sidebar's
/// `NavigationStack` in `MacShellView` and pushed when the user clicks
/// a topic-enabled group in the chats list.
struct TopicListSidebarView: View {
    let parent: Conversation

    @StateObject private var router = AppRouter.shared
    @ObservedObject private var presence = PresenceStore.shared
    @State private var showCreate = false

    private var memberSubtitle: String {
        let participants = parent.participantsOrEmpty.map(\.login)
        if participants.isEmpty {
            return "Members"
        }
        let onlineCount = participants.filter { presence.isOnline($0) }.count
        if onlineCount > 0 {
            return "\(participants.count) members · \(onlineCount) online"
        }
        return "\(participants.count) members"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TopicListContent(
                parent: parent,
                activeTopicId: router.selectedTopic?.topic.id,
                showCreate: $showCreate,
                onPickTopic: { picked in
                    router.pickTopic(picked, in: parent)
                }
            )
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
        }
        .task {
            // PresenceStore is reactive; ensure presence subscriptions
            // are warmed up for everyone in this parent group so the
            // online-count subtitle stays accurate.
            presence.ensure(parent.participantsOrEmpty.map(\.login))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    router.exitTopicMode()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color("AccentColor"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to chats")

                Text(parent.displayEmoji)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color("AccentColor").opacity(0.15))
                    )

                Text(parent.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color("AccentColor"))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .macHover()
                .accessibilityLabel("New Topic")
            }

            Text(memberSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 36)   // align under group name
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
```

- [ ] **Step 2: Verify `Conversation.displayEmoji` exists, or pick a fallback**

```bash
grep -n "displayEmoji" GitchatIOS/Core/Models/Models.swift
```

If `Conversation` does not expose `displayEmoji`: replace `Text(parent.displayEmoji)` in `header` with:

```swift
Text(String(parent.displayTitle.prefix(1)))
    .font(.system(size: 14, weight: .semibold))
    .foregroundStyle(Color("AccentColor"))
```

(Use the first character of the title as a stand-in.) If `displayEmoji` does exist, leave the original as-is.

- [ ] **Step 3: Verify `Conversation.participantsOrEmpty` exists**

```bash
grep -n "participantsOrEmpty" GitchatIOS/Core/Models/Models.swift
```

This is referenced from `ChatDetailTitleBar.swift` — should exist. If grep returns nothing, the spec needs a fallback path; flag and stop.

- [ ] **Step 4: Regenerate Xcode project and verify file is wired in**

```bash
xcodegen generate
grep -c "TopicListSidebarView.swift" GitchatIOS.xcodeproj/project.pbxproj
```

Expected: `≥ 2` (file ref + build phase ref).

- [ ] **Step 5: Compile Catalyst**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`. (iOS compile is a no-op for this file because it is gated on `#if targetEnvironment(macCatalyst)`, but run it anyway:)

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListSidebarView.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(ios): TopicListSidebarView — Catalyst sidebar header + body wrapper"
```

---

## Task 5: Create `TopicListPushView` (iOS)

**Files:**
- Create: `GitchatIOS/Features/Conversations/Topics/TopicListPushView.swift`

- [ ] **Step 1: Create the file with full implementation**

```swift
import SwiftUI

/// iOS pushed view (NavigationStack child) that hosts `TopicListContent`.
/// Pushed from `ConversationsListView` when the user taps a
/// topic-enabled group. Renders a custom 2-line title (group name +
/// member subtitle) in the toolbar and a trailing "+" to create topics.
/// Tapping a topic row pushes `ChatDetailView(.topic(...))` via the
/// embedding NavigationStack's `navigationDestination`.
struct TopicListPushView: View {
    let parent: Conversation
    let onPickTopic: (Topic) -> Void

    @ObservedObject private var presence = PresenceStore.shared
    @State private var showCreate = false

    private var memberSubtitle: String {
        let participants = parent.participantsOrEmpty.map(\.login)
        if participants.isEmpty { return "Members" }
        let onlineCount = participants.filter { presence.isOnline($0) }.count
        if onlineCount > 0 {
            return "\(participants.count) members · \(onlineCount) online"
        }
        return "\(participants.count) members"
    }

    var body: some View {
        TopicListContent(
            parent: parent,
            activeTopicId: nil,
            showCreate: $showCreate,
            onPickTopic: onPickTopic
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(parent.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(memberSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .accessibilityLabel("New Topic")
            }
        }
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
            .presentationDetents([.medium])
        }
        .task {
            presence.ensure(parent.participantsOrEmpty.map(\.login))
        }
    }
}
```

- [ ] **Step 2: Regenerate Xcode project and verify**

```bash
xcodegen generate
grep -c "TopicListPushView.swift" GitchatIOS.xcodeproj/project.pbxproj
```

Expected: `≥ 2`.

- [ ] **Step 3: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListPushView.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(ios): TopicListPushView — iOS pushed wrapper for topic list"
```

---

## Task 6: Wire Catalyst sidebar `NavigationStack` + tab-switch transitions

**Files:**
- Modify: `GitchatIOS/Core/UI/MacShellView.swift`

- [ ] **Step 1: Wrap the Chats sidebar `case 0` in a `NavigationStack`**

Replace the entire `currentTabSidebar` computed view with:

```swift
    @ViewBuilder
    private var currentTabSidebar: some View {
        switch router.selectedTab {
        case 0:
            NavigationStack(path: Binding(
                get: { router.topicSidebarPath },
                set: { router.topicSidebarPath = $0 }
            )) {
                ConversationsListView()
                    .navigationDestination(for: TopicSidebarRoute.self) { route in
                        TopicListSidebarView(parent: route.parent)
                    }
            }
        case 1: DiscoverView()
        case 2: NotificationsView()
        case 3: FollowingView()
        case 4: MeView()
        default: EmptyView()
        }
    }
```

- [ ] **Step 2: Update `detailIdentity` to include the active topic**

Replace the existing `detailIdentity` computed view with:

```swift
    private var detailIdentity: String {
        let tab = router.selectedTab
        let convoId = router.selectedConversation?.id ?? "none"
        let profile = router.selectedProfile ?? "none"
        let topicId = router.selectedTopic?.topic.id ?? "none"
        return "tab-\(tab)-profile-\(profile)-convo-\(convoId)-topic-\(topicId)"
    }
```

- [ ] **Step 3: Update `detailPanel` to render topic chats**

Replace the existing `detailPanel` computed view with:

```swift
    @ViewBuilder
    private var detailPanel: some View {
        Group {
            if let login = router.selectedProfile {
                ProfileView(login: login)
            } else if let target = router.selectedTopic {
                ChatDetailView(conversation: target.parent)
                    .id("topic-\(target.topic.id)")
            } else if let convo = router.selectedConversation {
                ChatDetailView(conversation: convo)
            } else {
                ContentUnavailableCompat(
                    title: "Select a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Pick a chat from the sidebar to start reading."
                )
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
```

> Note: `ChatDetailView` currently resolves the active topic itself via `resolveTarget()` reading from `TopicListStore`. The router's `selectedTopic` aligns with the same store. The `.id("topic-\(target.topic.id)")` modifier forces a fresh `ChatDetailView` instance per topic so its `vm.setTarget` and `resolvedTarget` initialize correctly.

- [ ] **Step 4: Compile Catalyst**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`.

- [ ] **Step 5: iOS compile (no-op safety check)**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Core/UI/MacShellView.swift
git commit -m "feat(ios): wire Catalyst sidebar NavigationStack for topic mode + topic detail panel"
```

---

## Task 7: Wire row tap handlers in `ConversationsListView`

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift`
- Modify: `GitchatIOS/Core/UI/AppRouter.swift`

The row tap routing is centralized in `openConversation(_:)` at line 310. Modifying that single function plus the existing `navigationDestination(for: Conversation.self)` (line 423) covers all 11 callsites used elsewhere in the file (search results, deep links, etc).

We accept that search results and deep-link taps also enter topic mode for topic-enabled groups — this is consistent and the simplest implementation.

- [ ] **Step 1: Add `TopicChatRoute` to `AppRouter.swift`**

Immediately below the `TopicSidebarRoute` definition (added in Task 1), add:

```swift
/// Route used on iOS to push a topic chat from the topic list view.
struct TopicChatRoute: Hashable {
    let topic: Topic
    let parent: Conversation
}
```

> `Topic` and `Conversation` already conform to `Hashable` in `Models.swift` (verify with `grep -n "Hashable" GitchatIOS/Core/Models/Models.swift`). If either does not conform, add the conformance — both types only contain value-type fields.

- [ ] **Step 2: Update `openConversation(_:)` to branch on `hasTopicsEnabled`**

Replace the entire body of `openConversation(_:)` (lines 310-321 in the pre-edit file) with:

```swift
    private func openConversation(_ convo: Conversation) {
        tappedConvoId = convo.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { tappedConvoId = nil }
        }
        vm.markLocallyRead(convo.id)
        #if targetEnvironment(macCatalyst)
        if convo.hasTopicsEnabled {
            router.enterTopicMode(parent: convo)
        } else {
            router.selectedConversation = convo
        }
        #else
        if convo.hasTopicsEnabled {
            path.append(TopicSidebarRoute(parent: convo))
        } else {
            path.append(convo)
        }
        #endif
    }
```

- [ ] **Step 3: Add `navigationDestination` modifiers for the new route types (iOS)**

Locate the existing `.navigationDestination(for: Conversation.self) { convo in ... }` modifier (line 423). Add the two new destinations as siblings on the same `NavigationStack`:

```swift
                .navigationDestination(for: Conversation.self) { convo in
                    ChatDetailView(conversation: convo)
                }
                .navigationDestination(for: TopicSidebarRoute.self) { route in
                    TopicListPushView(parent: route.parent) { picked in
                        path.append(TopicChatRoute(topic: picked, parent: route.parent))
                    }
                }
                .navigationDestination(for: TopicChatRoute.self) { route in
                    ChatDetailView(conversation: route.parent)
                        .onAppear {
                            AppRouter.shared.pickTopic(route.topic, in: route.parent)
                        }
                }
```

> The first destination (`Conversation.self`) is the existing one — keep its body unchanged. The two `TopicSidebarRoute` / `TopicChatRoute` destinations are new.

- [ ] **Step 4: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift GitchatIOS/Core/UI/AppRouter.swift
git commit -m "feat(ios): row tap routes to topic mode for topic-enabled groups"
```

---

## Task 8: Update `ChatDetailTitleBar` tap behavior

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift`

- [ ] **Step 1: Replace `topicHeader` to split tap behavior by platform**

Replace the existing `topicHeader(topic:parent:)` body with:

```swift
    @ViewBuilder
    private func topicHeader(topic: Topic, parent: Conversation) -> some View {
        VStack(spacing: -2) {
            HStack(spacing: 4) {
                Text("\(topic.displayEmoji) \(topic.name)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                #if !targetEnvironment(macCatalyst)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                #endif
            }
            HStack(spacing: 2) {
                Text("in \(parent.displayTitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        #if !targetEnvironment(macCatalyst)
        .onTapGesture { onTap?() }
        #endif
    }
```

> Catalyst: no `.onTapGesture` and no chevron — the sidebar is the topic switcher; the title bar is decorative.
> iOS: keeps the existing tap callback. The caller in `ChatDetailView` will be rebound in Task 10 to `dismiss()`.

- [ ] **Step 2: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift
git commit -m "feat(ios): topic title bar — Catalyst no-op tap, iOS keeps tap for dismiss"
```

---

## Task 9: Remove `TopicTabsStrip` integration + delete file

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`
- Delete: `GitchatIOS/Features/Conversations/Topics/TopicTabsStrip.swift`

- [ ] **Step 1: Remove the `safeAreaInset(edge: .top)` block from `chatShell`**

In `ChatDetailView.swift`, locate the block at lines 292-306 (the `#if targetEnvironment(macCatalyst) ... .safeAreaInset(edge: .top, spacing: 0) { ... } #endif`) and delete it entirely. After deletion, the surrounding code should flow from the prior modifier directly into `.navigationTitle("")`.

The exact block to remove:

```swift
        #if targetEnvironment(macCatalyst)
        .safeAreaInset(edge: .top, spacing: 0) {
            if vm.conversation.hasTopicsEnabled,
               case .topic(_, let parent) = resolvedTarget {
                TopicTabsStrip(
                    parent: parent,
                    activeTopicId: resolvedTarget?.conversationId,
                    onPickTopic: { picked in
                        vm.setTarget(.topic(picked, parent: parent))
                        resolvedTarget = .topic(picked, parent: parent)
                    }
                )
            }
        }
        #endif
```

- [ ] **Step 2: Delete `TopicTabsStrip.swift`**

```bash
rm GitchatIOS/Features/Conversations/Topics/TopicTabsStrip.swift
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
xcodegen generate
```

- [ ] **Step 4: Verify the file is no longer referenced**

```bash
grep -c "TopicTabsStrip" GitchatIOS.xcodeproj/project.pbxproj
grep -rn "TopicTabsStrip" GitchatIOS --include='*.swift'
```

Both should return `0` references.

- [ ] **Step 5: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetailView.swift GitchatIOS.xcodeproj/project.pbxproj
git rm GitchatIOS/Features/Conversations/Topics/TopicTabsStrip.swift
git commit -m "refactor(ios): remove Catalyst TopicTabsStrip — sidebar is now the switcher"
```

---

## Task 10: Remove `TopicListSheet` integration + delete file + iOS title bar dismiss

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`
- Delete: `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift`

- [ ] **Step 1: Remove the `.sheet(isPresented: $showTopicSheet)` block**

In `ChatDetailView.swift`, locate lines 158-174 (the `#if !targetEnvironment(macCatalyst) ... .sheet(isPresented: $showTopicSheet) { ... } #endif`) and delete the entire block.

The exact block to remove:

```swift
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showTopicSheet) {
            if case .topic(_, let parent) = resolvedTarget {
                TopicListSheet(
                    parent: parent,
                    activeTopicId: resolvedTarget?.conversationId,
                    onPickTopic: { picked in
                        vm.setTarget(.topic(picked, parent: parent))
                        resolvedTarget = .topic(picked, parent: parent)
                        showTopicSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        #endif
```

- [ ] **Step 2: Remove the `showTopicSheet` state declaration**

Delete the line:

```swift
    @State private var showTopicSheet = false
```

(at line 48 per pre-edit grep).

- [ ] **Step 3: Rebind iOS title bar tap to `dismiss()`**

Locate the `ToolbarItem(placement: .principal)` block where `ChatDetailTitleBar` is constructed with `onTap:`. The current handler sets `showTopicSheet = true` for topic targets. Replace its body to use the SwiftUI `dismiss` environment action.

First, ensure the environment is available. Near the top of `ChatDetailView`'s property declarations, add:

```swift
    @Environment(\.dismiss) private var dismiss
```

Then update the `onTap:` handler in the `ToolbarItem(placement: .principal)`:

```swift
            ToolbarItem(placement: .principal) {
                ChatDetailTitleBar(
                    conversation: vm.conversation,
                    vm: vm,
                    onTap: {
                        if case .topic = vm.target {
                            #if !targetEnvironment(macCatalyst)
                            dismiss()
                            #endif
                        } else if vm.conversation.isGroup {
                            showMembers = true
                        }
                    }
                )
            }
```

- [ ] **Step 4: Find and remove the second `showTopicSheet = true` site at line 511**

```bash
grep -n "showTopicSheet" GitchatIOS/Features/Conversations/ChatDetailView.swift
```

If a usage remains (it appeared at line 511 in the pre-edit grep — likely a long-press or context-menu site), remove that line as well. After removal, this grep should return zero matches.

- [ ] **Step 5: Delete `TopicListSheet.swift`**

```bash
rm GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift
```

- [ ] **Step 6: Regenerate Xcode project and verify clean**

```bash
xcodegen generate
grep -c "TopicListSheet" GitchatIOS.xcodeproj/project.pbxproj
grep -rn "TopicListSheet" GitchatIOS --include='*.swift'
```

Both must return `0`.

- [ ] **Step 7: Compile both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetailView.swift GitchatIOS.xcodeproj/project.pbxproj
git rm GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift
git commit -m "refactor(ios): remove TopicListSheet — iOS title bar tap pops to topic list"
```

---

## Task 11: Detect realtime archive of the active topic

**Files:**
- Modify: `GitchatIOS/Core/UI/MacShellView.swift`

The detail panel's host (Catalyst) needs to react when the topic the user is reading gets archived by another client. Same logic on iOS is implicit because the `NavigationStack` will simply leave the user on a topic that no longer exists in the store — acceptable as a v1 trade-off; iOS handling can be added in a follow-up if needed.

- [ ] **Step 1: Add an `.onReceive` to the detail panel that watches the topic store**

In `MacShellView.body`, inside the `NavigationSplitView` declaration, attach to the detail content:

```swift
            NavigationStack {
                detailPanel
            }
            .id(detailIdentity)
            .onReceive(TopicListStore.shared.objectWillChange) { _ in
                guard let active = router.selectedTopic else { return }
                let topics = TopicListStore.shared.topics(forParent: active.parent.id)
                if !topics.contains(where: { $0.id == active.topic.id }) {
                    ToastCenter.shared.show(.info, "Topic archived",
                                            "It was archived by another member")
                    router.exitTopicMode()
                }
            }
```

- [ ] **Step 2: Compile Catalyst**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`.

- [ ] **Step 3: iOS compile sanity**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```

`BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Core/UI/MacShellView.swift
git commit -m "feat(ios): toast + exit topic mode when active topic gets archived realtime"
```

---

## Task 12: Final verification — scenarios + cleanup

**Files:** none (verification only)

- [ ] **Step 1: Clean build both platforms**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS clean
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -20
```

Both `BUILD SUCCEEDED`.

- [ ] **Step 2: Verify `project.pbxproj` is clean**

```bash
# New files present
grep -c "TopicListSidebarView.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "TopicListPushView.swift"    GitchatIOS.xcodeproj/project.pbxproj
# Deleted files absent
grep -c "TopicTabsStrip"             GitchatIOS.xcodeproj/project.pbxproj
grep -c "TopicListSheet"             GitchatIOS.xcodeproj/project.pbxproj
```

Expected: first two `≥ 2`, last two `0`.

- [ ] **Step 3: Run all 12 manual scenarios from spec §6.2**

Boot a simulator + Catalyst app and walk through each:

```
1.  Catalyst: click topic-enabled group  → sidebar swaps, detail = General
2.  Catalyst: click another topic        → detail re-renders, active row highlights
3.  Catalyst: click "‹ Back"             → sidebar pops, detail = placeholder
4.  Catalyst: click "+" in sidebar       → TopicCreateSheet opens, new topic appears
5.  Either:   pin/unpin via context menu → row reorders with spring animation
6.  iOS:      tap topic-enabled group    → TopicListPushView pushes
7.  iOS:      tap topic row              → ChatDetailView pushes; back returns
8.  Either:   click non-topic group      → existing behavior, no swap
9.  Either:   topic-enabled empty group  → polished empty state shown
10. Catalyst: visual check               → no tab strip above chat body
11. Either:   member online change       → subtitle "N online" updates live
12. Catalyst: archive active topic       → toast shows, sidebar pops
```

For each, mark pass/fail. If any fails, file an issue against the failing scenario and revisit the relevant task before merging.

- [ ] **Step 4: Push branch and open PR draft**

```bash
git push -u origin hiru-topics-rework-entry
gh pr create --draft --title "refactor(ios): topics entry & navigation rework (Spec A of #112)" \
  --body "$(cat <<'EOF'
## Summary
- Telegram Forum-style sidebar swap on Mac Catalyst (replaces topic popover + tab strip)
- iOS direct push navigation (replaces bottom sheet)
- TopicRow visually twinned to ConversationRow (44/64 avatar, sender:preview, accent active state)
- Polished empty state, spring pin reorder, archived-topic-detection

Spec: docs/superpowers/specs/2026-05-06-topics-entry-navigation-rework-design.md
Plan: docs/superpowers/plans/2026-05-06-topics-entry-navigation-rework-plan.md

## Test plan
- [ ] Catalyst: 12 scenarios from spec §6.2 pass on a booted Mac
- [ ] iOS Simulator: scenarios 5-9 pass on iPhone 15
- [ ] No `TopicTabsStrip` / `TopicListSheet` references remain
- [ ] Compile clean for both destinations

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

If `gh` PR creation fails (no remote, no auth), skip and create the PR manually — the branch is pushed.

---

## Notes for the executing engineer

**Ordering invariants:**
- Task 1 (router state) must land before any task that references `router.topicSidebarPath`, `router.selectedTopic`, `enterTopicMode`, `pickTopic`, or `exitTopicMode`. Tasks 4-11 all depend on Task 1.
- Tasks 4 and 5 (new view files) must land before Task 6 (MacShellView wiring) and Task 7 (ConversationsListView wiring).
- Task 9 (delete `TopicTabsStrip`) must land *after* Task 6 but can land *before* the chats-list wiring of Task 7 — `TopicTabsStrip` is referenced only from `ChatDetailView`'s `safeAreaInset` block, which Task 9 itself removes.
- Task 10 (delete `TopicListSheet`) must land *after* Task 8 — Task 8 prepares the iOS title bar tap to be a no-op handle that Task 10 finishes wiring to `dismiss()`.

**If a step fails to compile:**
- Read the compiler error, fix at the failing site, re-run the same command.
- Do not skip ahead. Don't `--no-verify` or otherwise bypass — investigate the error.
- If a referenced symbol (`Conversation.displayEmoji`, `participantsOrEmpty`, etc.) is missing, grep the codebase for the closest analogous expression and adapt — do not introduce a new model property as part of this rework.

**Git hygiene:**
- One commit per task (Tasks 0 and 12 may have no commit body of their own).
- Commit messages follow the existing `feat(ios)` / `refactor(ios)` / `docs(spec)` prefix style visible in `git log`.

# iOS Topic Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer the Topic feature (sub-conversations with emoji icons, color tokens, pin order, archive lifecycle, per-topic unread counts, realtime updates) on top of Slug's PR #89 chat foundation, in parity with the VS Code extension UX.

**Architecture:** Distinct `Topic` struct + `ChatTarget` enum (`.conversation` | `.topic`) drive the existing `ChatViewModel`. Topics are presented via a bottom sheet from `ChatDetailTitleBar`; selection swaps the active `ChatTarget`. Backend broadcasts every topic event into `conversation:{parentId}` so the iOS client only needs to subscribe to the parent room.

**Spec:** [`docs/superpowers/specs/2026-04-28-ios-topic-feature-design.md`](../specs/2026-04-28-ios-topic-feature-design.md) — read first.

**Tech Stack:** Swift 5.9, SwiftUI (iOS 16+ deployment target), `socket.io-client-swift`, `swiftui-toasts`, XCTest, XcodeGen.

**Branch strategy:** Off `main` post-PR-#89-merge, named `vincent-ios-topic-feature` (or similar `<git-user>-<feature>`). One PR at the end. Per the iOS issue-fix workflow, do not push or open the PR until the user has manually verified the feature.

**TDD ordering:** Pure-logic units (model decode, store mutations, endpoint URL builders, socket payload decoders, color resolver) come first with unit tests in `GitchatIOSTests/`. SwiftUI views are wired after the units they depend on are green; views are smoke-tested manually per §8.2 of the spec since the repo has no SwiftUI snapshot harness.

**Commit cadence:** One commit per task (most tasks). Two-commit refactor split for the `ChatViewModel` signature change (Task 1 first, then Tasks 9 + 10 layer behavior).

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `GitchatIOSTests/Info.plist` | Unit-test bundle plist |
| `GitchatIOSTests/TopicDecodingTests.swift` | `Topic` JSON decode coverage |
| `GitchatIOSTests/ChatTargetTests.swift` | `ChatTarget` resolution helpers |
| `GitchatIOSTests/TopicColorTokenTests.swift` | Color token resolver |
| `GitchatIOSTests/APIClientTopicURLTests.swift` | Endpoint URL building |
| `GitchatIOSTests/TopicListStoreTests.swift` | Store mutations + sort + LRU |
| `GitchatIOSTests/TopicSocketEventTests.swift` | Socket payload decode |
| `GitchatIOSTests/ChatViewModelEndpointTests.swift` | sendEndpoint / fetchEndpoint branching |
| `GitchatIOS/Core/UI/TopicColor.swift` | `TopicColorToken` enum + Color resolution |
| `GitchatIOS/Core/Networking/APIClient+Topic.swift` | All v1 topic endpoints |
| `GitchatIOS/Core/Realtime/TopicSocketEvent.swift` | Typed enum for the seven topic events |
| `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift` | Observable per-parent topic cache |
| `GitchatIOS/Features/Conversations/Topics/TopicEmojiPresets.swift` | The 12 preset emojis |
| `GitchatIOS/Features/Conversations/Topics/TopicRow.swift` | Row component for the sheet |
| `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift` | Bottom-sheet topic list |
| `GitchatIOS/Features/Conversations/Topics/TopicCreateSheet.swift` | Create form |
| `GitchatIOS/Resources/Assets.xcassets/TopicColorRed.colorset/` | + 7 more colorsets (Orange / Yellow / Green / Cyan / Blue / Purple / Pink), each with light + dark variants |

### Modified

| Path | Change |
|---|---|
| `project.yml` | Add `GitchatIOSTests` target + register in scheme |
| `GitchatIOS/Core/Models/Models.swift` | Add `Topic` struct, `ChatTarget` enum, `topics_enabled: Bool?` on `Conversation` |
| `GitchatIOS/Core/OutboxStore.swift` | Add `topicID: String?` + `parentConversationID: String?` on `PendingMessage` (camelCase, matches house style) + endpoint resolution branching |
| `GitchatIOS/Core/Realtime/SocketClient.swift` | Subscribe handlers for the seven topic events; emit through `NotificationCenter` (multi-consumer) |
| `GitchatIOS/Features/Conversations/ConversationsCache.swift` | Add `patchLastMessage(...)` setter |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | Lazy target resolution + sheet hosting |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift` | Emoji + topic name + parent subtitle + chevron + tap action |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` | `init(target:)`, branched send/fetch endpoints, dedup `message:sent` vs `topic:message` |

After every task that touches `project.yml` or adds a new file, run `xcodegen generate`. Never hand-edit `GitchatIOS.xcodeproj/project.pbxproj`.

---

## Task 0: Add `GitchatIOSTests` unit-test target

The repo today only has `GitchatIOSUITests` (UI tests). All pure-logic tests in this plan need a non-UI XCTest bundle.

**Files:**
- Modify: `project.yml`
- Create: `GitchatIOSTests/Info.plist`
- Create: `GitchatIOSTests/.gitkeep` (placeholder so the directory exists before files are added; remove after first real test lands)

- [ ] **Step 1: Add the target to `project.yml`**

Append under the existing `GitchatIOSUITests:` block (around line 244):

```yaml
  GitchatIOSTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - path: GitchatIOSTests
    dependencies:
      - target: GitchatIOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: chat.git.tests
        TEST_TARGET_NAME: GitchatIOS
        SUPPORTS_MACCATALYST: YES
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
    info:
      path: GitchatIOSTests/Info.plist
      properties:
        CFBundleName: $(PRODUCT_NAME)
        CFBundlePackageType: BNDL
```

Then update the scheme's test targets (around line 18, the `schemes.GitchatIOS.test.targets` list):

```yaml
    test:
      config: Debug
      targets:
        - GitchatIOSTests
        - GitchatIOSUITests
```

- [ ] **Step 2: Create the test bundle directory + Info.plist**

```bash
mkdir -p GitchatIOSTests
touch GitchatIOSTests/.gitkeep
```

`Info.plist` is generated by xcodegen from the inline `info.properties` block above — no manual file needed.

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: "Loaded project" and "✅ Created project at ..." with no errors.

- [ ] **Step 4: Verify the test target builds**

Run: `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' build-for-testing -quiet`
Expected: `** TEST BUILD SUCCEEDED **`. The build will compile both `GitchatIOSTests` and `GitchatIOSUITests` because the scheme tests both.

- [ ] **Step 5: Commit**

```bash
git add project.yml GitchatIOSTests/.gitkeep GitchatIOS.xcodeproj/project.pbxproj
git commit -m "chore: add GitchatIOSTests unit-test target

Adds a XCTest bundle separate from GitchatIOSUITests so pure-logic
tests (model decode, view-model branching, socket payload parsing,
store mutations) can run without booting the UI host. Wired into the
GitchatIOS scheme so xcodebuild test runs both bundles."
```

---

## Task 1: `ChatTarget` enum + `ChatViewModel.init(target:)` refactor (no behavior change)

This is the spec's "two-commit refactor split" — first commit lands the type-level change with no observable behavior diff. The `Topic` struct itself is added in Task 2; here `ChatTarget` is monomorphic — only the `.conversation` case is reachable in production code so the user sees nothing different.

**Files:**
- Modify: `GitchatIOS/Core/Models/Models.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`
- Test: `GitchatIOSTests/ChatTargetTests.swift`

- [ ] **Step 1: Write the failing test for `ChatTarget`**

`GitchatIOSTests/ChatTargetTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

final class ChatTargetTests: XCTestCase {
    private let conv = Conversation.fixture(id: "conv-1")

    func testConversationCaseExposesItsId() {
        let t: ChatTarget = .conversation(conv)
        XCTAssertEqual(t.conversationId, "conv-1")
        XCTAssertNil(t.parentConversationId)
    }
}
```

You will need a `Conversation.fixture(id:)` helper. Add it inside the test file as a fileprivate extension:

```swift
fileprivate extension Conversation {
    static func fixture(id: String) -> Conversation {
        Conversation(
            id: id, type: "dm", is_group: false, group_name: nil,
            group_avatar_url: nil, repo_full_name: nil, participants: [],
            other_user: nil, last_message: nil, last_message_preview: nil,
            last_message_text: nil, last_message_at: nil, unread_count: 0,
            pinned: false, pinned_at: nil, is_request: false, updated_at: nil,
            is_muted: false, has_mention: false, has_reaction: false,
            topics_enabled: nil
        )
    }
}
```
Note: `topics_enabled` is added in **this** task — see Step 3.

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:GitchatIOSTests/ChatTargetTests -quiet 2>&1 | tail -20`
Expected: compile errors — `ChatTarget` undefined, `Conversation` missing `topics_enabled` parameter.

- [ ] **Step 3: Add `ChatTarget` + `topics_enabled` to Models.swift**

In `GitchatIOS/Core/Models/Models.swift`, inside the `Conversation` struct (lines ~30–107), add the new field after `has_reaction` and before `var isGroup: Bool`:

```swift
    let topics_enabled: Bool?

    var hasTopicsEnabled: Bool { topics_enabled == true }
```

`Conversation` has neither an explicit `init` nor an explicit `CodingKeys` enum — both are synthesized by the compiler. Adding the field is enough; the synthesized memberwise init and `Codable` conformance regenerate automatically. The only manual fix is the `withLastMessage(...)` helper (around Models.swift:83) which builds a `Conversation` via the keyword-argument memberwise init — append `topics_enabled: topics_enabled` to that call. Run a build after editing to surface any other call sites the compiler complains about.

Then, **at the end of the `// MARK: - Conversation / Message` section but before `// MARK: - Auth`**, append:

```swift
// MARK: - ChatTarget

enum ChatTarget: Hashable {
    case conversation(Conversation)
    // Note: .topic case is added in Task 2 once the Topic struct exists.
    // For now ChatTarget is monomorphic so the refactor lands without
    // behavioral change.

    var conversationId: String {
        switch self {
        case .conversation(let c): return c.id
        }
    }

    var parentConversationId: String? {
        switch self {
        case .conversation: return nil
        }
    }
}
```

- [ ] **Step 4: Run the test — should now pass**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/ChatTargetTests -quiet 2>&1 | tail -10`
Expected: `Test Suite 'ChatTargetTests' passed`. If `Conversation.fixture` still fails, double-check the parameter list matches `Conversation.init` exactly (this is the most common Swift memberwise-init pitfall).

- [ ] **Step 5: Refactor `ChatViewModel.init` to take `ChatTarget`**

`ChatViewModel.swift:26` currently has `@Published var conversation: Conversation` — a stored property mutated when `conversation:updated` fires. We **replace** this stored property with a `@Published var target: ChatTarget`, plus a derived `conversation` computed property that handles **both** cases up front (no `fatalError` — the `.topic` case extracts the parent so legacy reads keep working as soon as topic targets land in Task 9):

```swift
final class ChatViewModel: ObservableObject {
    @Published private(set) var target: ChatTarget

    /// Legacy accessor. Returns the conversation for `.conversation` targets and
    /// the parent conversation for `.topic` targets — sufficient for every
    /// existing read site (draft key, mute lookup, participant list, etc.).
    var conversation: Conversation {
        switch target {
        case .conversation(let c): return c
        case .topic(_, let p):     return p
        }
    }

    init(target: ChatTarget) {
        self.target = target
        // Keep the rest of the init body unchanged. Reads of `self.conversation`
        // continue to work via the computed property above.
    }
}
```

**Audit every `self.conversation = ...` write site** in `ChatViewModel.swift` (the `conversation:updated` listener and any draft/mute reload paths). Replace each assignment with `self.target = .conversation(updatedConversation)` where the assignment used to land. Where the existing code uses `$conversation` for Combine subscriptions, switch to `$target` and map to the underlying `Conversation` if needed.

Add a backwards-compatible convenience overload to ease the call-site sweep:

```swift
extension ChatViewModel {
    convenience init(conversation: Conversation) {
        self.init(target: .conversation(conversation))
    }
}
```

Note: marking `target` `private(set)` means external mutation must go through a setter method. For Task 9's swap-on-pick flow we'll add `func setTarget(_ newTarget: ChatTarget)` in Task 10; for Task 1 itself, no external writes happen so private(set) is fine.

- [ ] **Step 6: Update `ChatDetailView` to use the new init**

In `GitchatIOS/Features/Conversations/ChatDetailView.swift`, find the ViewModel construction site (likely `@StateObject private var vm: ChatViewModel` initialized either inline or in `.onAppear`/`.task`) and verify it uses the convenience init `ChatViewModel(conversation: conversation)` — the convenience extension above means no change is required at this site if it already passes a `Conversation`.

If anywhere else in the codebase a `ChatViewModel(...)` is built with positional args, replace with the new shape. Grep:

Run: `grep -rn "ChatViewModel(" GitchatIOS --include="*.swift"`
Expected: every call site is either `ChatViewModel(conversation:)` (compiles via convenience) or already updated.

- [ ] **Step 7: Build the full app to verify the refactor**

Run: `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' build -quiet`
Expected: `** BUILD SUCCEEDED **`. Run any existing UI tests that touch chat: `xcodebuild ... test -only-testing:GitchatIOSUITests -quiet 2>&1 | tail -20` — should still pass.

- [ ] **Step 8: Commit**

```bash
git add GitchatIOS/Core/Models/Models.swift \
        GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift \
        GitchatIOSTests/ChatTargetTests.swift
git commit -m "refactor(chat): introduce ChatTarget enum + ChatViewModel(target:)

Foundational refactor with no behavioral change. ChatViewModel now
takes a ChatTarget; the .conversation case is the only reachable one
today. Convenience init(conversation:) keeps every existing call site
compiling. Adds topics_enabled: Bool? to Conversation so the next
patch can light up the topic surface without touching this file again.

Spec: docs/superpowers/specs/2026-04-28-ios-topic-feature-design.md §3.5"
```

---

## Task 2: `Topic` struct + `.topic` case on `ChatTarget`

**Files:**
- Modify: `GitchatIOS/Core/Models/Models.swift`
- Test: `GitchatIOSTests/TopicDecodingTests.swift`

- [ ] **Step 1: Write the failing decode tests**

`GitchatIOSTests/TopicDecodingTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

final class TopicDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> Topic {
        try JSONDecoder().decode(Topic.self, from: Data(json.utf8))
    }

    func testFullPayloadDecodes() throws {
        let json = """
        {
          "id": "topic-1", "parent_conversation_id": "conv-1",
          "name": "Bug Reports", "icon_emoji": "🐛", "color_token": "red",
          "is_general": false, "pin_order": 1,
          "archived_at": null,
          "last_message_at": "2026-04-28T10:00:00Z",
          "last_message_preview": "broken on iPad",
          "last_sender_login": "alice",
          "unread_count": 3, "unread_mentions_count": 1, "unread_reactions_count": 0,
          "created_by": "alice", "created_at": "2026-04-20T08:00:00Z"
        }
        """
        let t = try decode(json)
        XCTAssertEqual(t.id, "topic-1")
        XCTAssertEqual(t.color_token, "red")
        XCTAssertTrue(t.isPinned)
        XCTAssertFalse(t.isArchived)
        XCTAssertTrue(t.hasMention)
        XCTAssertFalse(t.hasReaction)
        XCTAssertEqual(t.displayEmoji, "🐛")
    }

    func testGeneralTopicDecodes() throws {
        let t = try decode("""
        { "id":"g","parent_conversation_id":"p","name":"General","is_general":true,
          "unread_count":0,"unread_mentions_count":0,"unread_reactions_count":0,
          "created_by":"alice","created_at":"2026-04-20T08:00:00Z" }
        """)
        XCTAssertTrue(t.is_general)
        XCTAssertNil(t.icon_emoji)
        XCTAssertEqual(t.displayEmoji, "💬")              // default fallback
        XCTAssertNil(t.pin_order)
        XCTAssertFalse(t.isPinned)
    }

    func testArchivedTopicDecodes() throws {
        let t = try decode("""
        { "id":"a","parent_conversation_id":"p","name":"Old","is_general":false,
          "archived_at":"2026-04-25T10:00:00Z",
          "unread_count":0,"unread_mentions_count":0,"unread_reactions_count":0,
          "created_by":"x","created_at":"2026-04-01T00:00:00Z" }
        """)
        XCTAssertTrue(t.isArchived)
    }

    func testChatTargetTopicCase() {
        let conv = Conversation.fixture(id: "conv-1")
        let topic = Topic.fixture(id: "topic-1", parentId: "conv-1")
        let t: ChatTarget = .topic(topic, parent: conv)
        XCTAssertEqual(t.conversationId, "topic-1")
        XCTAssertEqual(t.parentConversationId, "conv-1")
    }
}

extension Topic {
    static func fixture(id: String, parentId: String, isGeneral: Bool = false,
                        pinOrder: Int? = nil, unread: Int = 0) -> Topic {
        Topic(id: id, parent_conversation_id: parentId, name: "T",
              icon_emoji: nil, color_token: nil, is_general: isGeneral,
              pin_order: pinOrder, archived_at: nil,
              last_message_at: nil, last_message_preview: nil, last_sender_login: nil,
              unread_count: unread, unread_mentions_count: 0, unread_reactions_count: 0,
              created_by: "x", created_at: "2026-04-20T08:00:00Z")
    }
}

// Conversation.fixture stays in ChatTargetTests.swift; tests in this file
// import @testable so the visibility is fine.
```

- [ ] **Step 2: Run — verify it fails**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicDecodingTests -quiet 2>&1 | tail -20`
Expected: `Topic` undefined, `ChatTarget.topic` undefined.

- [ ] **Step 3: Add `Topic` struct + extend `ChatTarget`**

In `GitchatIOS/Core/Models/Models.swift`, **before** `// MARK: - ChatTarget`, add:

```swift
// MARK: - Topic

struct Topic: Codable, Identifiable, Hashable {
    let id: String
    let parent_conversation_id: String
    let name: String
    let icon_emoji: String?
    let color_token: String?
    let is_general: Bool
    let pin_order: Int?
    let archived_at: String?
    let last_message_at: String?
    let last_message_preview: String?
    let last_sender_login: String?
    let unread_count: Int
    let unread_mentions_count: Int
    let unread_reactions_count: Int
    let created_by: String
    let created_at: String

    var isArchived: Bool { archived_at != nil }
    var isPinned: Bool { pin_order != nil }
    var displayEmoji: String { icon_emoji ?? "💬" }
    var hasMention: Bool { unread_mentions_count > 0 }
    var hasReaction: Bool { unread_reactions_count > 0 }
}
```

Then update `ChatTarget`:

```swift
enum ChatTarget: Hashable {
    case conversation(Conversation)
    case topic(Topic, parent: Conversation)

    var conversationId: String {
        switch self {
        case .conversation(let c): return c.id
        case .topic(let t, _): return t.id
        }
    }

    var parentConversationId: String? {
        switch self {
        case .conversation: return nil
        case .topic(_, let p): return p.id
        }
    }
}
```

- [ ] **Step 4: Run — verify it passes**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicDecodingTests -quiet 2>&1 | tail -10`
Expected: `Test Suite 'TopicDecodingTests' passed`. The `ChatViewModel.conversation` computed property already handles the `.topic` case (returns the parent) since Task 1 — no further change needed.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Models/Models.swift GitchatIOSTests/TopicDecodingTests.swift
git commit -m "feat(models): add Topic struct + ChatTarget.topic case

Topic is decoded with snake_case keys to match Conversation. Defaults
displayEmoji to 💬 when icon_emoji is nil (matches extension).
ChatTarget gains the .topic case carrying both the topic and its
parent — the parent is required for endpoint construction (BE quirk:
sendTopicMessage path is /messages/conversations/:parentId/topics/:topicId/messages)."
```

---

## Task 3: `TopicColor.swift` + 8 colorset assets

**Files:**
- Create: `GitchatIOS/Core/UI/TopicColor.swift`
- Create: `GitchatIOS/Resources/Assets.xcassets/TopicColorRed.colorset/Contents.json` (and 7 more — Orange, Yellow, Green, Cyan, Blue, Purple, Pink)
- Test: `GitchatIOSTests/TopicColorTokenTests.swift`

- [ ] **Step 1: Write the failing test**

`GitchatIOSTests/TopicColorTokenTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

final class TopicColorTokenTests: XCTestCase {
    func testKnownTokens() {
        XCTAssertEqual(TopicColorToken.resolve("red"), .red)
        XCTAssertEqual(TopicColorToken.resolve("BLUE"), .blue)        // case-insensitive
        XCTAssertEqual(TopicColorToken.resolve("orange"), .orange)
    }

    func testNilOrUnknownReturnsBlue() {
        XCTAssertEqual(TopicColorToken.resolve(nil), .blue)
        XCTAssertEqual(TopicColorToken.resolve("magenta"), .blue)     // not in BE enum
    }

    func testAllCasesCovered() {
        // Eight tokens matching backend ColorToken enum
        XCTAssertEqual(TopicColorToken.allCases.count, 8)
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicColorTokenTests -quiet 2>&1 | tail -10`
Expected: `TopicColorToken` undefined.

- [ ] **Step 3: Implement `TopicColor.swift`**

`GitchatIOS/Core/UI/TopicColor.swift`:
```swift
import SwiftUI

enum TopicColorToken: String, CaseIterable, Hashable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    var color: Color {
        switch self {
        case .red:    return Color("TopicColorRed")
        case .orange: return Color("TopicColorOrange")
        case .yellow: return Color("TopicColorYellow")
        case .green:  return Color("TopicColorGreen")
        case .cyan:   return Color("TopicColorCyan")
        case .blue:   return Color("TopicColorBlue")
        case .purple: return Color("TopicColorPurple")
        case .pink:   return Color("TopicColorPink")
        }
    }

    /// Defaults to `.blue` for nil or any unrecognized token, matching the BE default.
    static func resolve(_ rawToken: String?) -> TopicColorToken {
        guard let raw = rawToken else { return .blue }
        return TopicColorToken(rawValue: raw.lowercased()) ?? .blue
    }
}
```

- [ ] **Step 4: Create the eight colorset assets**

For each of the eight colors, create `GitchatIOS/Resources/Assets.xcassets/TopicColor<Name>.colorset/Contents.json` with the values below. Use Apple HIG semantic palette RGB so dark mode adapts automatically.

Light + dark RGB pairs (sRGB, 0–255 → divide by 255 for `red/green/blue` floats — Xcode's asset format uses 0–1):

| Token | Light (R, G, B) | Dark (R, G, B) |
|---|---|---|
| Red | 255, 59, 48 | 255, 69, 58 |
| Orange | 255, 149, 0 | 255, 159, 10 |
| Yellow | 255, 204, 0 | 255, 214, 10 |
| Green | 52, 199, 89 | 48, 209, 88 |
| Cyan | 50, 173, 230 | 100, 210, 255 |
| Blue | 0, 122, 255 | 10, 132, 255 |
| Purple | 175, 82, 222 | 191, 90, 242 |
| Pink | 255, 45, 85 | 255, 55, 95 |

Template `Contents.json` (substitute floats — divide each integer by 255 and round to 3 decimals):

```json
{
  "colors": [
    {
      "color": {
        "color-space": "srgb",
        "components": { "alpha": "1.000", "red": "1.000", "green": "0.231", "blue": "0.188" }
      },
      "idiom": "universal"
    },
    {
      "appearances": [{ "appearance": "luminosity", "value": "dark" }],
      "color": {
        "color-space": "srgb",
        "components": { "alpha": "1.000", "red": "1.000", "green": "0.271", "blue": "0.227" }
      },
      "idiom": "universal"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

The above is **TopicColorRed**. Repeat for the other seven tokens with the values from the table.

- [ ] **Step 5: Regenerate Xcode project (resources need to be re-indexed)**

Run: `xcodegen generate`
Expected: regeneration succeeds; the new colorsets show up in the Asset Catalog when Xcode opens.

- [ ] **Step 6: Run the test**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicColorTokenTests -quiet 2>&1 | tail -10`
Expected: passes. Note: the `Color("TopicColor*")` lookups are not exercised by these tests because `Color(...)` resolves at render time; they are sanity-checked manually in Task 7's preview.

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Core/UI/TopicColor.swift \
        GitchatIOS/Resources/Assets.xcassets/TopicColor*.colorset \
        GitchatIOSTests/TopicColorTokenTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(ui): add TopicColorToken + 8 colorset assets

Eight colors matching the BE enum (red, orange, yellow, green, cyan,
blue, purple, pink), each with a light/dark variant from the Apple
HIG semantic palette so dark mode contrast is correct out of the box.
TopicColorToken.resolve falls back to .blue for nil or unknown tokens
(matches BE default)."
```

---

## Task 4: `APIClient+Topic.swift` networking

**Files:**
- Create: `GitchatIOS/Core/Networking/APIClient+Topic.swift`
- Test: `GitchatIOSTests/APIClientTopicURLTests.swift` (URL builder + body shape unit tests — no live network)

- [ ] **Step 1: Write the failing tests**

We unit-test the **request body shapes and path strings** by introducing a thin pure helper for path/body construction. The actual `APIClient.request(...)` is a thin wrapper exercised in manual testing.

Sketch the helpers in `APIClient+Topic.swift` itself so they can be tested:

`GitchatIOSTests/APIClientTopicURLTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

final class APIClientTopicURLTests: XCTestCase {

    func testListPath() {
        XCTAssertEqual(TopicEndpoints.list(parentId: "p"),
                       "messages/conversations/p/topics")
    }

    func testCreatePath() {
        XCTAssertEqual(TopicEndpoints.create(parentId: "p"),
                       "messages/conversations/p/topics")
    }

    func testArchivePath() {
        XCTAssertEqual(TopicEndpoints.archive(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/archive")
    }

    func testPinPath() {
        XCTAssertEqual(TopicEndpoints.pin(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/pin")
    }

    func testSendMessagePath() {
        XCTAssertEqual(TopicEndpoints.sendMessage(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/messages")
    }

    func testListQueryItemsRespectFlags() {
        let q = TopicEndpoints.listQuery(includeArchived: true,
                                          pinnedOnly: false, limit: 50)
        XCTAssertEqual(q.first(where: { $0.name == "includeArchived" })?.value, "true")
        XCTAssertEqual(q.first(where: { $0.name == "pinnedOnly" })?.value, "false")
        XCTAssertEqual(q.first(where: { $0.name == "limit" })?.value, "50")
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/APIClientTopicURLTests -quiet 2>&1 | tail -10`
Expected: `TopicEndpoints` undefined.

- [ ] **Step 3: Implement `APIClient+Topic.swift`**

`GitchatIOS/Core/Networking/APIClient+Topic.swift`:
```swift
import Foundation

// MARK: - Endpoint path / query builders (testable)

enum TopicEndpoints {
    static func list(parentId: String) -> String {
        "messages/conversations/\(parentId)/topics"
    }
    static func create(parentId: String) -> String {
        "messages/conversations/\(parentId)/topics"
    }
    static func archive(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/archive"
    }
    static func pin(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/pin"
    }
    static func unpin(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/unpin"
    }
    static func read(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/read"
    }
    static func sendMessage(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/messages"
    }
    static func fetchMessages(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/messages"
    }

    static func listQuery(includeArchived: Bool, pinnedOnly: Bool, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "includeArchived", value: String(includeArchived)),
            URLQueryItem(name: "pinnedOnly", value: String(pinnedOnly)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }
}

// MARK: - APIClient extension

extension APIClient {

    struct ListTopicsResponse: Decodable { let topics: [Topic] }

    struct CreateTopicBody: Encodable {
        let name: String
        let iconEmoji: String?
        let colorToken: String?
    }

    struct PinTopicBody: Encodable { let order: Int }

    func fetchTopics(parentId: String,
                     includeArchived: Bool = false,
                     pinnedOnly: Bool = false,
                     limit: Int = 100) async throws -> [Topic] {
        let resp: ListTopicsResponse = try await request(
            TopicEndpoints.list(parentId: parentId),
            query: TopicEndpoints.listQuery(includeArchived: includeArchived,
                                            pinnedOnly: pinnedOnly, limit: limit)
        )
        return resp.topics
    }

    func createTopic(parentId: String,
                     name: String,
                     iconEmoji: String?,
                     colorToken: String?) async throws -> Topic {
        try await request(
            TopicEndpoints.create(parentId: parentId),
            method: "POST",
            body: CreateTopicBody(name: name, iconEmoji: iconEmoji, colorToken: colorToken)
        )
    }

    func archiveTopic(parentId: String, topicId: String) async throws -> Topic {
        try await request(TopicEndpoints.archive(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: EmptyBody())
    }

    func pinTopic(parentId: String, topicId: String, order: Int) async throws -> Topic {
        try await request(TopicEndpoints.pin(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: PinTopicBody(order: order))
    }

    func unpinTopic(parentId: String, topicId: String) async throws -> Topic {
        try await request(TopicEndpoints.unpin(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: EmptyBody())
    }

    func markTopicRead(parentId: String, topicId: String) async throws {
        let _: EmptyResponse = try await request(
            TopicEndpoints.read(parentId: parentId, topicId: topicId),
            method: "PATCH",
            body: EmptyBody()
        )
    }
}

private struct EmptyBody: Encodable {}
```

If `EmptyResponse` does not exist in `Models.swift` yet, add `struct EmptyResponse: Decodable {}` near the top of that file (or check — the existing `APIEnvelope<T>` may already have a usable shape).

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/APIClientTopicURLTests -quiet 2>&1 | tail -10`
Expected: passes. Build the full app to verify the extension compiles end-to-end:

Run: `xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Networking/APIClient+Topic.swift \
        GitchatIOSTests/APIClientTopicURLTests.swift \
        GitchatIOS/Core/Models/Models.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(api): add APIClient+Topic with 8 v1 endpoints

list, create, archive, pin, unpin, mark-read, sendTopicMessage,
fetchTopicMessages. Path strings extracted into TopicEndpoints enum
so they can be unit-tested without booting the network. Out-of-scope
endpoints (update, unarchive, delete, close, reopen, hide-general,
permissions, settings) deliberately omitted per spec §1.2."
```

---

## Task 5: `TopicListStore` observable cache

**Files:**
- Create: `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift`
- Test: `GitchatIOSTests/TopicListStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`GitchatIOSTests/TopicListStoreTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

@MainActor
final class TopicListStoreTests: XCTestCase {

    func testAppendInsertsTopicForParent() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p1"), parentId: "p1")
        XCTAssertEqual(store.topics(forParent: "p1").count, 1)
    }

    func testSortPinnedBeforeUnpinned() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "u1", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "p2", parentId: "p", pinOrder: 2), parentId: "p")
        store.append(Topic.fixture(id: "p1", parentId: "p", pinOrder: 1), parentId: "p")

        let order = store.topics(forParent: "p").map(\.id)
        XCTAssertEqual(order, ["p1", "p2", "u1"])  // pin asc, then unpinned
    }

    func testArchiveRemovesFromList() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p"), parentId: "p")
        store.archive(topicId: "t1", parentId: "p")
        XCTAssertTrue(store.topics(forParent: "p").isEmpty)
    }

    func testApplyEventCreated() {
        let store = TopicListStore()
        let t = Topic.fixture(id: "t1", parentId: "p")
        store.applyEvent(.created(parentId: "p", topic: t))
        XCTAssertEqual(store.topics(forParent: "p").count, 1)
    }

    func testApplyEventPinnedReorders() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "a", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "b", parentId: "p"), parentId: "p")
        store.applyEvent(.pinned(parentId: "p", topicId: "b", pinOrder: 1))
        XCTAssertEqual(store.topics(forParent: "p").map(\.id), ["b", "a"])
    }

    func testBumpUnreadIncrementsCount() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t", parentId: "p", unread: 2), parentId: "p")
        store.bumpUnread(topicId: "t", parentId: "p", by: 1)
        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 3)
    }

    func testLRUEvictsOldestParent() {
        let store = TopicListStore(maxParents: 2)
        store.append(Topic.fixture(id: "x", parentId: "p1"), parentId: "p1")
        store.append(Topic.fixture(id: "x", parentId: "p2"), parentId: "p2")
        store.append(Topic.fixture(id: "x", parentId: "p3"), parentId: "p3")  // evicts p1
        XCTAssertTrue(store.topics(forParent: "p1").isEmpty)
        XCTAssertEqual(store.topics(forParent: "p2").count, 1)
        XCTAssertEqual(store.topics(forParent: "p3").count, 1)
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicListStoreTests -quiet 2>&1 | tail -20`
Expected: `TopicListStore` undefined.

- [ ] **Step 3: Implement the store**

`GitchatIOS/Features/Conversations/Topics/TopicListStore.swift`:
```swift
import Foundation
import Combine

@MainActor
final class TopicListStore: ObservableObject {
    static let shared = TopicListStore()

    @Published private(set) var topicsByParent: [String: [Topic]] = [:]

    private var lru: [String] = []                       // recently accessed parentIds (front = newest)
    private let maxParents: Int

    init(maxParents: Int = 10) {
        self.maxParents = maxParents
    }

    // MARK: - Reads

    func topics(forParent parentId: String) -> [Topic] {
        topicsByParent[parentId] ?? []
    }

    // MARK: - Writes

    func setTopics(_ topics: [Topic], forParent parentId: String) {
        topicsByParent[parentId] = sort(topics)
        touchLRU(parentId)
    }

    func append(_ topic: Topic, parentId: String) {
        var arr = topicsByParent[parentId] ?? []
        if let idx = arr.firstIndex(where: { $0.id == topic.id }) {
            arr[idx] = topic
        } else {
            arr.append(topic)
        }
        topicsByParent[parentId] = sort(arr)
        touchLRU(parentId)
    }

    func update(topicId: String, parentId: String, mutate: (inout Topic) -> Void) {
        guard var arr = topicsByParent[parentId],
              let idx = arr.firstIndex(where: { $0.id == topicId }) else { return }
        mutate(&arr[idx])
        topicsByParent[parentId] = sort(arr)
    }

    func archive(topicId: String, parentId: String) {
        guard var arr = topicsByParent[parentId] else { return }
        arr.removeAll { $0.id == topicId }
        topicsByParent[parentId] = arr
    }

    func setPinOrder(topicId: String, parentId: String, order: Int?) {
        update(topicId: topicId, parentId: parentId) { t in
            t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                      name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
                      is_general: t.is_general, pin_order: order, archived_at: t.archived_at,
                      last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
                      last_sender_login: t.last_sender_login, unread_count: t.unread_count,
                      unread_mentions_count: t.unread_mentions_count,
                      unread_reactions_count: t.unread_reactions_count,
                      created_by: t.created_by, created_at: t.created_at)
        }
    }

    func bumpUnread(topicId: String, parentId: String, by delta: Int) {
        update(topicId: topicId, parentId: parentId) { t in
            let new = max(0, t.unread_count + delta)
            t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                      name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
                      is_general: t.is_general, pin_order: t.pin_order, archived_at: t.archived_at,
                      last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
                      last_sender_login: t.last_sender_login, unread_count: new,
                      unread_mentions_count: t.unread_mentions_count,
                      unread_reactions_count: t.unread_reactions_count,
                      created_by: t.created_by, created_at: t.created_at)
        }
    }

    func clearUnread(topicId: String, parentId: String) {
        bumpUnread(topicId: topicId, parentId: parentId, by: -.max)
    }

    func applyEvent(_ event: TopicSocketEvent) {
        switch event {
        case .created(let parentId, let topic):
            append(topic, parentId: parentId)
        case .updated(let parentId, let topicId, let changes):
            update(topicId: topicId, parentId: parentId) { t in
                t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                          name: changes.name ?? t.name,
                          icon_emoji: changes.iconEmoji ?? t.icon_emoji,
                          color_token: changes.colorToken ?? t.color_token,
                          is_general: t.is_general, pin_order: t.pin_order,
                          archived_at: t.archived_at, last_message_at: t.last_message_at,
                          last_message_preview: t.last_message_preview,
                          last_sender_login: t.last_sender_login, unread_count: t.unread_count,
                          unread_mentions_count: t.unread_mentions_count,
                          unread_reactions_count: t.unread_reactions_count,
                          created_by: t.created_by, created_at: t.created_at)
            }
        case .archived(let parentId, let topicId):
            archive(topicId: topicId, parentId: parentId)
        case .pinned(let parentId, let topicId, let order):
            setPinOrder(topicId: topicId, parentId: parentId, order: order)
        case .unpinned(let parentId, let topicId):
            setPinOrder(topicId: topicId, parentId: parentId, order: nil)
        case .settingsUpdated, .message:
            // Settings + message events are handled by callers, not the store.
            break
        }
    }

    // MARK: - Private

    private func sort(_ arr: [Topic]) -> [Topic] {
        arr.sorted { l, r in
            switch (l.pin_order, r.pin_order) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return (l.last_message_at ?? "") > (r.last_message_at ?? "")
            }
        }
    }

    private func touchLRU(_ parentId: String) {
        lru.removeAll { $0 == parentId }
        lru.insert(parentId, at: 0)
        while lru.count > maxParents, let drop = lru.popLast() {
            topicsByParent.removeValue(forKey: drop)
        }
    }
}
```

Note: `TopicSocketEvent` and its `changes` payload are added in Task 6. To keep this task green right now, **stub the type at the top of `TopicListStore.swift`** and replace it in Task 6:

```swift
// TEMP — replaced by Core/Realtime/TopicSocketEvent.swift in Task 6
enum TopicSocketEvent {
    case created(parentId: String, topic: Topic)
    case updated(parentId: String, topicId: String, changes: TopicUpdateChanges)
    case archived(parentId: String, topicId: String)
    case pinned(parentId: String, topicId: String, pinOrder: Int)
    case unpinned(parentId: String, topicId: String)
    case settingsUpdated(parentId: String, topicsEnabled: Bool)
    case message(parentId: String, topicId: String, message: Message)
}
struct TopicUpdateChanges { let name: String?; let iconEmoji: String?; let colorToken: String? }
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicListStoreTests -quiet 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListStore.swift \
        GitchatIOSTests/TopicListStoreTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(topics): add TopicListStore observable cache

@MainActor ObservableObject keyed by parentId, sorted pinned-first
(pin asc) then unpinned by last_message_at desc. LRU eviction at 10
parents matches ConversationsCache. applyEvent handles created /
updated / archived / pinned / unpinned (settings + message routed
elsewhere). TopicSocketEvent stubbed inline; replaced in next commit."
```

---

## Task 6: `TopicSocketEvent` enum + `SocketClient` topic subscribers + `ConversationsCache.patchLastMessage`

**Files:**
- Create: `GitchatIOS/Core/Realtime/TopicSocketEvent.swift`
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift` (remove the temp stub from Task 5)
- Modify: `GitchatIOS/Core/Realtime/SocketClient.swift`
- Modify: `GitchatIOS/Features/Conversations/ConversationsCache.swift`
- Test: `GitchatIOSTests/TopicSocketEventTests.swift`

- [ ] **Step 1: Write the failing tests**

`GitchatIOSTests/TopicSocketEventTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

final class TopicSocketEventTests: XCTestCase {

    private let topicJSON: [String: Any] = [
        "id": "t1", "parent_conversation_id": "p1",
        "name": "Bugs", "icon_emoji": "🐛", "color_token": "red",
        "is_general": false, "pin_order": NSNull(),
        "archived_at": NSNull(),
        "last_message_at": NSNull(), "last_message_preview": NSNull(),
        "last_sender_login": NSNull(),
        "unread_count": 0, "unread_mentions_count": 0, "unread_reactions_count": 0,
        "created_by": "alice", "created_at": "2026-04-20T08:00:00Z"
    ]

    func testCreatedEventDecodes() throws {
        let payload: [String: Any] = ["parentId": "p1", "topic": topicJSON]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:created", payload: payload))
        guard case .created(let parentId, let topic) = evt else { return XCTFail("wrong case") }
        XCTAssertEqual(parentId, "p1")
        XCTAssertEqual(topic.id, "t1")
    }

    func testPinnedEventDecodes() throws {
        let payload: [String: Any] = ["parentId":"p1","topicId":"t1","pinOrder":2]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:pinned", payload: payload))
        guard case .pinned(_, _, let order) = evt else { return XCTFail("wrong case") }
        XCTAssertEqual(order, 2)
    }

    func testArchivedEventDecodes() throws {
        let payload: [String: Any] = ["parentId":"p1","topicId":"t1"]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:archived", payload: payload))
        if case .archived(let p, let t) = evt {
            XCTAssertEqual(p, "p1"); XCTAssertEqual(t, "t1")
        } else { XCTFail("wrong case") }
    }

    func testUnknownEventReturnsNil() {
        XCTAssertNil(TopicSocketEvent.from(eventName: "topic:closed", payload: [:]))
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicSocketEventTests -quiet 2>&1 | tail -10`
Expected: `TopicSocketEvent.from` undefined.

- [ ] **Step 3: Implement `TopicSocketEvent.swift`**

`GitchatIOS/Core/Realtime/TopicSocketEvent.swift`:
```swift
import Foundation

enum TopicSocketEvent {
    case created(parentId: String, topic: Topic)
    case updated(parentId: String, topicId: String, changes: TopicUpdateChanges)
    case archived(parentId: String, topicId: String)
    case pinned(parentId: String, topicId: String, pinOrder: Int)
    case unpinned(parentId: String, topicId: String)
    case settingsUpdated(parentId: String, topicsEnabled: Bool)
    case message(parentId: String, topicId: String, message: Message)

    /// Decode a Socket.IO payload (already unwrapped from the outer envelope) into a typed event.
    /// Returns nil for events outside v1 scope (closed, reopened, deleted, unarchived).
    static func from(eventName: String, payload: [String: Any]) -> TopicSocketEvent? {
        let parentId = payload["parentId"] as? String
                    ?? payload["conversationId"] as? String   // ext naming variant

        switch eventName {
        case "topic:created":
            guard let parentId,
                  let topicDict = payload["topic"] as? [String: Any],
                  let topic = decodeTopic(topicDict) else { return nil }
            return .created(parentId: parentId, topic: topic)

        case "topic:updated":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            let changes = TopicUpdateChanges(
                name: payload["name"] as? String,
                iconEmoji: payload["iconEmoji"] as? String,
                colorToken: payload["colorToken"] as? String
            )
            return .updated(parentId: parentId, topicId: topicId, changes: changes)

        case "topic:archived":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            return .archived(parentId: parentId, topicId: topicId)

        case "topic:pinned":
            guard let parentId,
                  let topicId = payload["topicId"] as? String,
                  let order = payload["pinOrder"] as? Int else { return nil }
            return .pinned(parentId: parentId, topicId: topicId, pinOrder: order)

        case "topic:unpinned":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            return .unpinned(parentId: parentId, topicId: topicId)

        case "topic:settings-updated":
            guard let parentId else { return nil }
            let enabled = (payload["topicsEnabled"] as? Bool) ?? false
            return .settingsUpdated(parentId: parentId, topicsEnabled: enabled)

        case "topic:message":
            guard let parentId,
                  let topicId = payload["topicId"] as? String,
                  let msgDict = payload["message"] as? [String: Any] ?? payload as [String: Any]?,
                  let msg = decodeMessage(msgDict) else { return nil }
            return .message(parentId: parentId, topicId: topicId, message: msg)

        default:
            return nil   // closed / reopened / deleted / unarchived deferred to v2
        }
    }

    private static func decodeTopic(_ dict: [String: Any]) -> Topic? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Topic.self, from: data)
    }

    private static func decodeMessage(_ dict: [String: Any]) -> Message? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: data)
    }
}

struct TopicUpdateChanges: Hashable {
    let name: String?
    let iconEmoji: String?
    let colorToken: String?
}
```

- [ ] **Step 4: Remove the temp stub from `TopicListStore.swift`**

Delete the `// TEMP — replaced by ...` block from Task 5. Build to verify:

Run: `xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run socket-event tests — they should pass**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests/TopicSocketEventTests -quiet 2>&1 | tail -10`
Expected: passes.

- [ ] **Step 6: Wire `SocketClient` to dispatch topic events**

In `GitchatIOS/Core/Realtime/SocketClient.swift`, add a callback alongside the existing ones (around line 50):

```swift
    var onTopicEvent: ((TopicSocketEvent) -> Void)?
```

Inside the `connect()` method, after the existing `socket.on("conversation:updated") { ... }` block, register the seven topic events. To avoid duplicating the inner `data.first` unwrap dance, factor a helper at the bottom of the class:

```swift
    private func payloadDict(_ data: [Any]) -> [String: Any]? {
        guard let dict = data.first as? [String: Any] else { return nil }
        return (dict["data"] as? [String: Any]) ?? dict
    }
```

Then the seven handlers:

```swift
        let topicEvents = [
            "topic:created", "topic:updated", "topic:archived",
            "topic:pinned", "topic:unpinned", "topic:settings-updated",
            "topic:message",
        ]
        for evtName in topicEvents {
            socket.on(evtName) { [weak self] data, _ in
                guard let payload = self?.payloadDict(data),
                      let evt = TopicSocketEvent.from(eventName: evtName, payload: payload) else { return }
                Task { @MainActor in
                    self?.onTopicEvent?(evt)
                    NotificationCenter.default.post(name: .gitchatTopicEvent, object: evt)
                }
            }
        }
```

Add the notification name. At the bottom of `SocketClient.swift` (or wherever the existing `Notification.Name` extensions live):

```swift
extension Notification.Name {
    static let gitchatTopicEvent = Notification.Name("gitchatTopicEvent")
}
```

- [ ] **Step 7: Add `ConversationsCache.patchLastMessage(...)`**

In `GitchatIOS/Features/Conversations/ConversationsCache.swift`, add a method:

```swift
    @MainActor
    func patchLastMessage(conversationId: String,
                          text: String?, at: String?, sender: String?) {
        guard var c = conversation(id: conversationId) else { return }
        c = Conversation(/* memberwise; overwrite last_message_text / last_message_at /
                            last_sender_login / updated_at; copy the rest from c */)
        upsert(c)
    }
```

The exact implementation depends on how `ConversationsCache` currently stores rows — likely an `@Published var conversations: [Conversation]`. Replicate the existing upsert pattern. Add a dedicated 1-arg helper if the existing API lacks one.

- [ ] **Step 8: Build the app**

Run: `xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add GitchatIOS/Core/Realtime/TopicSocketEvent.swift \
        GitchatIOS/Core/Realtime/SocketClient.swift \
        GitchatIOS/Features/Conversations/Topics/TopicListStore.swift \
        GitchatIOS/Features/Conversations/ConversationsCache.swift \
        GitchatIOSTests/TopicSocketEventTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(realtime): TopicSocketEvent enum + SocketClient topic subscribers

Subscribes to the seven v1 topic events on the existing parent room.
Emits via a callback + NotificationCenter post so multiple consumers
(TopicListStore, ChatViewModel, ConversationsCache) can react without
fighting for the single onTopicEvent callback. ConversationsCache
gets a patchLastMessage helper so the topic:message handler can
freshen the parent row without a REST round-trip."
```

---

## Task 7: `TopicListSheet` + `TopicRow` + `TopicEmojiPresets`

**Files:**
- Create: `GitchatIOS/Features/Conversations/Topics/TopicEmojiPresets.swift`
- Create: `GitchatIOS/Features/Conversations/Topics/TopicRow.swift`
- Create: `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift`

This task is UI — verified by SwiftUI Preview + manual smoke. Pure-logic helpers (sort order, badge visibility) are already covered by Task 5's tests.

- [ ] **Step 1: Add the 12 emoji presets**

`GitchatIOS/Features/Conversations/Topics/TopicEmojiPresets.swift`:
```swift
import Foundation

enum TopicEmojiPresets {
    /// 12 presets, mirroring the VS Code extension exactly. Default selection: 💬.
    static let all: [String] = ["💬","🐛","🚀","📋","📌","💡","🎯","⚙️","📊","🔥","✨","📚"]
    static let `default`: String = "💬"
}
```

- [ ] **Step 2: Implement `TopicRow`**

`GitchatIOS/Features/Conversations/Topics/TopicRow.swift`:
```swift
import SwiftUI

struct TopicRow: View {
    let topic: Topic
    let isActive: Bool
    let onTap: () -> Void

    @ScaledMetric(relativeTo: .caption) private var mentionBadgeSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var badgeMinSize: CGFloat = 18

    private var color: Color { TopicColorToken.resolve(topic.color_token).color }

    var body: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text("\(topic.displayEmoji) \(topic.name)")
                    .font(.headline).foregroundStyle(.primary)
                    .lineLimit(1)
                if let preview = topic.last_message_preview {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let ts = topic.last_message_at {
                    Text(RelativeTime.short(ts)).font(.footnote).foregroundStyle(.tertiary)
                }
                badges
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 44)                             // HIG touch target
        .background(isActive ? Color("AccentColor").opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
    }

    private var iconSquare: some View {
        Text(topic.displayEmoji)
            .font(.title3)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if topic.unread_count > 0 {
                if topic.hasMention {
                    Text("@").font(.caption.bold())
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(Color("AccentColor"), in: Circle())
                        .foregroundStyle(.white)
                }
                if topic.hasReaction {
                    Image(systemName: "heart.fill").font(.system(size: 10))
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(Color("AccentColor"), in: Circle())
                        .foregroundStyle(.white)
                }
                Text(topic.unread_count > 99 ? "99+" : "\(topic.unread_count)")
                    .font(.footnote.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(minWidth: badgeMinSize, minHeight: badgeMinSize)
                    .background(Color("AccentColor"), in: .capsule)
                    .foregroundStyle(.white)
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        TopicRow(topic: .fixturePreview(id: "g", name: "General", emoji: "💬",
                                         unread: 0, isPinned: true), isActive: true, onTap: {})
        TopicRow(topic: .fixturePreview(id: "b", name: "Bugs", emoji: "🐛",
                                         unread: 12, mentions: 1, isPinned: true),
                 isActive: false, onTap: {})
        TopicRow(topic: .fixturePreview(id: "v", name: "v2.0", emoji: "🚀",
                                         unread: 1, color: "red"), isActive: false, onTap: {})
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
#endif
```

If `RelativeTime` doesn't have a `.short(_ iso: String)` static method, fall back to whatever helper exists today (search `Core/UI/RelativeTime.swift` and use the same API the conversation list uses — likely a method on a `Date` formatter).

- [ ] **Step 3: Implement `TopicListSheet`**

`GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift`:
```swift
import SwiftUI

struct TopicListSheet: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @StateObject private var store = TopicListStore.shared
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false

    private var topics: [Topic] { store.topics(forParent: parent.id) }
    private var pinned: [Topic] { topics.filter { $0.isPinned } }
    private var unpinned: [Topic] { topics.filter { !$0.isPinned } }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Topics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCreate = true } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }.accessibilityLabel("New Topic")
                    }
                }
                .sheet(isPresented: $showCreate) {
                    TopicCreateSheet(parent: parent) { newTopic in
                        store.append(newTopic, parentId: parent.id)
                    }
                    .presentationDetents([.medium])
                }
                .task { await load() }
                .onReceive(NotificationCenter.default.publisher(for: .gitchatTopicEvent)) { note in
                    if let evt = note.object as? TopicSocketEvent { store.applyEvent(evt) }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorBanner(err)
        } else if isLoading && topics.isEmpty {
            loadingPlaceholder
        } else if topics.isEmpty {
            emptyState
        } else {
            list
        }
    }

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
        .listRowSeparator(.hidden)
    }

    private func row(for topic: Topic) -> some View {
        TopicRow(topic: topic, isActive: topic.id == activeTopicId) {
            onPickTopic(topic)
        }
        .contextMenu { contextMenu(for: topic) }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private func contextMenu(for topic: Topic) -> some View {
        Button { Task { await markRead(topic) } } label: {
            Label("Mark as read", systemImage: "checkmark.circle")
        }
        if topic.isPinned {
            Button { Task { await unpin(topic) } } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        } else {
            Menu {
                ForEach(1...5, id: \.self) { slot in
                    Button("Slot \(slot)") { Task { await pin(topic, order: slot) } }
                }
            } label: {
                Label("Pin to position…", systemImage: "pin")
            }
        }
        if !topic.is_general {
            Button(role: .destructive) { Task { await archive(topic) } } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("💬").font(.system(size: 48))
            Text("No topics yet").font(.title3).foregroundStyle(.primary)
            Text("Create one to organize discussions")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("+ New Topic") { showCreate = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4) { _ in
                HStack { Color.gray.opacity(0.18).frame(height: 60).cornerRadius(8) }
                    .padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(spacing: 12) {
            Text(err).font(.subheadline).foregroundStyle(.red)
            Button("Retry") { Task { await load() } }
        }.padding(24)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            let fetched = try await APIClient.shared.fetchTopics(parentId: parent.id)
            store.setTopics(fetched, forParent: parent.id)
        } catch { loadError = "Could not load topics — try again" }
        isLoading = false
    }

    private func markRead(_ t: Topic) async {
        store.clearUnread(topicId: t.id, parentId: parent.id)
        try? await APIClient.shared.markTopicRead(parentId: parent.id, topicId: t.id)
    }

    /// Helper shared with Task 8 — substring-match the BE error body to detect
    /// a typed error code, since `APIError.http` carries the raw body, not a
    /// parsed code.
    private static func isErrorCode(_ code: String, in body: String?) -> Bool {
        (body ?? "").contains(code)
    }

    private func pin(_ t: Topic, order: Int) async {
        do {
            let updated = try await APIClient.shared.pinTopic(parentId: parent.id,
                                                               topicId: t.id, order: order)
            store.append(updated, parentId: parent.id)
        } catch {
            ToastCenter.shared.show(.error, "Could not pin", "Try another slot")
        }
    }

    private func unpin(_ t: Topic) async {
        do {
            let updated = try await APIClient.shared.unpinTopic(parentId: parent.id,
                                                                 topicId: t.id)
            store.append(updated, parentId: parent.id)
        } catch {
            ToastCenter.shared.show(.error, "Could not unpin", nil)
        }
    }

    private func archive(_ t: Topic) async {
        do {
            _ = try await APIClient.shared.archiveTopic(parentId: parent.id, topicId: t.id)
            store.archive(topicId: t.id, parentId: parent.id)
        } catch {
            ToastCenter.shared.show(.error, "Could not archive", "Only the creator or an admin can archive this topic")
        }
    }
}
```

The toast surface in this repo is `ToastCenter.shared.show(_ kind: Toast.Kind, _ title: String, _ subtitle: String? = nil)` (see `GitchatIOS/Core/UI/Toast.swift`). `kind` is one of `.success / .info / .warning / .error`. **Replace every `Toast.show(...)` snippet that appears later in this plan** (Tasks 8, 10, 11) with the same `ToastCenter.shared.show(...)` shape — the plan was drafted with a placeholder API.

Other `ToastCenter` calls in this task:
- `pin` failure: `ToastCenter.shared.show(.error, "Could not pin", "Try another slot")`
- `unpin` failure: `ToastCenter.shared.show(.error, "Could not unpin", nil)`

- [ ] **Step 4: Build the app**

Run: `xcodegen generate && xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`. Open the Xcode preview for `TopicRow` and visually inspect: row spacing 12pt, emoji square 36×36 with tinted bg, headline + secondary preview, time top-right, badge bottom-right.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicEmojiPresets.swift \
        GitchatIOS/Features/Conversations/Topics/TopicRow.swift \
        GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(topics): TopicListSheet + TopicRow

Bottom-sheet topic list with Pinned + All topics sections, long-press
context menu (mark read / pin to slot / unpin / archive), empty/
loading/error states. Subscribes to NotificationCenter
.gitchatTopicEvent so the list updates live without manual refresh.
TopicRow mirrors ConversationsListView mention/reaction badge pattern
exactly (no shared helper exists today)."
```

---

## Task 8: `TopicCreateSheet` form

**Files:**
- Create: `GitchatIOS/Features/Conversations/Topics/TopicCreateSheet.swift`

- [ ] **Step 1: Implement the form**

`GitchatIOS/Features/Conversations/Topics/TopicCreateSheet.swift`:
```swift
import SwiftUI

struct TopicCreateSheet: View {
    let parent: Conversation
    let onCreated: (Topic) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedEmoji: String = TopicEmojiPresets.default
    @State private var selectedColor: TopicColorToken = .blue
    @State private var inFlight = false
    @State private var nameError: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inFlight
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Bug Reports", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                    if let err = nameError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("Topic name") }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TopicEmojiPresets.all, id: \.self) { emoji in
                                emojiButton(emoji)
                            }
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Icon") }

                Section {
                    HStack(spacing: 12) {
                        ForEach(TopicColorToken.allCases, id: \.self) { token in
                            colorDot(token)
                        }
                    }.padding(.vertical, 4)
                } header: { Text("Color") }
            }
            .navigationTitle("New Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await submit() } }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        let selected = emoji == selectedEmoji
        return Button { selectedEmoji = emoji } label: {
            Text(emoji).font(.title2)
                .frame(width: 44, height: 44)
                .background(selected ? Color("AccentColor").opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color("AccentColor") : .clear, lineWidth: 2))
        }.buttonStyle(.plain)
    }

    private func colorDot(_ token: TopicColorToken) -> some View {
        let selected = token == selectedColor
        return Button { selectedColor = token } label: {
            Circle().fill(token.color)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? Color("AccentColor") : .clear, lineWidth: 3)
                    .padding(-3))
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain)
    }

    private func submit() async {
        inFlight = true; nameError = nil
        do {
            let topic = try await APIClient.shared.createTopic(
                parentId: parent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                iconEmoji: selectedEmoji,
                colorToken: selectedColor.rawValue
            )
            onCreated(topic)
            ToastCenter.shared.show(.success, "Topic created", nil)
            dismiss()
        } catch let APIError.http(status, body) where status == 409
                                            && (body ?? "").contains("TOPIC_NAME_TAKEN") {
            nameError = "Name already in use"
        } catch let APIError.http(status, _) where status == 429 {
            ToastCenter.shared.show(.error, "You're creating topics too fast",
                                     "Try again later")
        } catch let APIError.http(status, _) where status == 403 {
            ToastCenter.shared.show(.error, "Only admins can create topics here", nil)
            dismiss()
        } catch {
            ToastCenter.shared.show(.error, "Could not create topic", "Try again")
        }
        inFlight = false
    }
}
```

`APIError.http(Int, String?)` carries the raw response body string as the second associated value (not a parsed error code). The `body.contains("TOPIC_NAME_TAKEN")` substring match is intentional — the BE response body is JSON like `{"error":"TOPIC_NAME_TAKEN", ...}`, and a contains check is robust against shape changes. Use the same pattern in Task 10 if any topic action needs to discriminate on a specific BE code.

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicCreateSheet.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(topics): TopicCreateSheet form

Form-style sheet with name + 12-emoji picker + 8-color picker. Default
selection 💬 + blue. Submit branches on BE error codes (TOPIC_NAME_TAKEN
inline, rate-limit + forbidden via toast). No optimistic insert in v1
— BE response gates the new row showing up."
```

---

## Task 9 + 10 (combined): topic-aware behavior — view, viewmodel, dedup, archive flow

> **Important:** Tasks 9 and 10 land **in a single commit**. Task 9 introduces the first `.topic` `ChatTarget` at runtime (via `resolveTarget()`); Task 10 lights up the topic-aware send/fetch endpoints and realtime handlers. Splitting them across two commits would leave the build technically green but the runtime would crash the moment a user opened a topics-enabled group, because `ChatViewModel.sendEndpoint` would still issue conversation-only paths until Task 10. Land them together. Keep the steps separated for clarity, and do a single commit at the end.

### Task 9 — `ChatDetailView` lazy resolve + sheet host + `ChatDetailTitleBar` chevron

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift`

- [ ] **Step 1: Update `ChatDetailTitleBar`**

In `GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift`, accept a target argument and render the topic-aware title:

```swift
struct ChatDetailTitleBar: View {
    let target: ChatTarget
    let onTap: () -> Void
    // ...keep existing right-side toolbar properties...

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText).font(.headline).lineLimit(1)
                if let subtitle = subtitleText {
                    HStack(spacing: 4) {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        if isTopic {
                            Image(systemName: "chevron.down").font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                }
            }
            Spacer()
            // ...existing right-side actions...
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isTopic { onTap() }
        }
    }

    private var isTopic: Bool {
        if case .topic = target { return true } else { return false }
    }
    private var titleText: String {
        switch target {
        case .conversation(let c): return c.displayTitle
        case .topic(let t, _):     return "\(t.displayEmoji) \(t.name)"
        }
    }
    private var subtitleText: String? {
        switch target {
        case .conversation:        return nil   // existing subtitle logic continues to apply
        case .topic(_, let p):     return "in \(p.displayTitle)"
        }
    }
    // avatar: parent's GroupAvatarView for .topic, existing avatar for .conversation
}
```

If the existing title bar already takes a `Conversation` (not a `ChatTarget`), this is the spot to switch its parameter. Update the call site in `ChatDetailView` accordingly.

- [ ] **Step 2: Refactor `ChatDetailView` to lazy-resolve**

In `GitchatIOS/Features/Conversations/ChatDetailView.swift`:

```swift
struct ChatDetailView: View {
    let conversation: Conversation

    @State private var resolvedTarget: ChatTarget? = nil
    @State private var showTopicSheet = false

    var body: some View {
        Group {
            if let target = resolvedTarget {
                inner(for: target)
                    .id(target.conversationId)        // re-init ChatViewModel on swap
            } else {
                ChatSkeleton()
            }
        }
        .task(id: conversation.id) { await resolveTarget() }
    }

    private func inner(for target: ChatTarget) -> some View {
        // wrap existing body (composer, list, headerbar) here, threading `target`
        // into ChatViewModel + ChatDetailTitleBar
        ChatScreen(target: target,
                   onHeaderTap: { showTopicSheet = true })
            .sheet(isPresented: $showTopicSheet) {
                if case .topic(_, let parent) = target {
                    TopicListSheet(
                        parent: parent,
                        activeTopicId: target.conversationId,
                        onPickTopic: { picked in
                            resolvedTarget = .topic(picked, parent: parent)
                            showTopicSheet = false
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
    }

    private func resolveTarget() async {
        if conversation.hasTopicsEnabled {
            do {
                let topics = try await APIClient.shared.fetchTopics(parentId: conversation.id)
                TopicListStore.shared.setTopics(topics, forParent: conversation.id)
                let general = topics.first(where: { $0.is_general }) ?? topics.first
                resolvedTarget = general.map { .topic($0, parent: conversation) }
                              ?? .conversation(conversation)
            } catch {
                resolvedTarget = .conversation(conversation)
            }
        } else {
            resolvedTarget = .conversation(conversation)
        }
    }
}
```

`ChatScreen` is the wrapper that contains the existing chat body (composer, message list, header bar). Extract it from the current `ChatDetailView` body, threading `target` through. The convenience init `ChatViewModel(conversation:)` is no longer needed inside `ChatScreen` — switch to `ChatViewModel(target: target)` directly.

`SocketClient.subscribe(conversation: conversation.id)` should already happen on the existing entry path. When `target` becomes `.topic`, we still subscribe to the **parent** room, not the topic id — leave the existing subscribe alone.

- [ ] **Step 3: Build and smoke-test**

Run: `xcodegen generate && xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`.

Boot the simulator and open a conversation **without** topics — the existing chat must look identical. Open a conversation **with** topics enabled — the title shows `💬 General`, the subtitle shows `in <group>` with a chevron, and tapping the title bar opens `TopicListSheet`.

- [ ] **Step 4: (no commit yet — Task 10 follows in the same commit)**

Run the build to verify the wiring compiles:

Run: `xcodegen generate && xcodebuild ... build -quiet`
Expected: `** BUILD SUCCEEDED **`. Smoke-running the simulator at this point will *open* a topic but **sends will go to the wrong endpoint** — that's expected and gets fixed by Task 10 below.

---

### Task 10 — ChatViewModel branched endpoints + topic message dedup + parent row patch + active-topic archive

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`
- Test: `GitchatIOSTests/ChatViewModelEndpointTests.swift`

- [ ] **Step 1: Write the failing endpoint test**

`GitchatIOSTests/ChatViewModelEndpointTests.swift`:
```swift
import XCTest
@testable import GitchatIOS

@MainActor
final class ChatViewModelEndpointTests: XCTestCase {
    func testConversationSendEndpoint() {
        let vm = ChatViewModel(target: .conversation(.fixture(id: "c")))
        XCTAssertEqual(vm.testHook_sendEndpoint, "messages/conversations/c")
    }

    func testTopicSendEndpoint() {
        let parent = Conversation.fixture(id: "p")
        let topic = Topic.fixture(id: "t", parentId: "p")
        let vm = ChatViewModel(target: .topic(topic, parent: parent))
        XCTAssertEqual(vm.testHook_sendEndpoint,
                       "messages/conversations/p/topics/t/messages")
    }
}
```

- [ ] **Step 2: Run — fails** (no `testHook_sendEndpoint`).

- [ ] **Step 3: Implement branched endpoints + dedup + parent patch**

In `ChatViewModel.swift`:

```swift
    var sendEndpoint: String {                   // make non-private for test access
        switch target {
        case .conversation(let c):
            return "messages/conversations/\(c.id)"
        case .topic(let t, let p):
            return "messages/conversations/\(p.id)/topics/\(t.id)/messages"
        }
    }
    #if DEBUG
    var testHook_sendEndpoint: String { sendEndpoint }
    #endif

    var fetchEndpoint: String {                  // same shape; used by initial load
        switch target {
        case .conversation(let c):
            return "messages/conversations/\(c.id)"
        case .topic(let t, let p):
            return "messages/conversations/\(p.id)/topics/\(t.id)/messages"
        }
    }
```

Switch every existing reference to `"messages/conversations/\(conversation.id)"` (and the matching message paths) to use these properties.

The `conversation` computed property was already implemented correctly in Task 1 (returns the parent for `.topic` targets) — no further change there.

Add a public setter so `ChatDetailView` can swap the active target on topic pick:

```swift
    func setTarget(_ newTarget: ChatTarget) {
        guard newTarget.conversationId != target.conversationId else { return }
        self.target = newTarget
        // Reset message state and re-fetch from the new endpoint
        self.messages = []
        Task { await self.loadInitialPage() }
    }
```

Update `ChatDetailView`'s `onPickTopic` closure to call `vm.setTarget(.topic(picked, parent: parent))` instead of relying on `.id(...)` to re-init the ViewModel. The `.id(target.conversationId)` modifier in Task 9's snippet is redundant once `setTarget` exists — drop it to avoid double-resetting.

Wire the topic message handlers via `NotificationCenter.gitchatTopicEvent`. In `ChatViewModel.init` (or `onAppear`):

```swift
    private var topicEventObserver: NSObjectProtocol?

    private func observeTopicEvents() {
        topicEventObserver = NotificationCenter.default.addObserver(
            forName: .gitchatTopicEvent, object: nil, queue: .main
        ) { [weak self] note in
            guard let evt = note.object as? TopicSocketEvent else { return }
            self?.handle(topicEvent: evt)
        }
    }

    private func handle(topicEvent evt: TopicSocketEvent) {
        switch evt {
        case .message(let parentId, let topicId, let message):
            // Patch parent conversation row in cache (avoid REST round-trip)
            ConversationsCache.shared.patchLastMessage(
                conversationId: parentId,
                text: message.previewText,
                at: message.created_at,
                sender: message.sender
            )
            // If active target == this topic → append to current chat
            if target.conversationId == topicId {
                ingestRealtimeMessage(message)              // existing handler
            } else {
                // Bump per-topic unread badge in store
                TopicListStore.shared.bumpUnread(topicId: topicId, parentId: parentId, by: 1)
            }
        case .archived(let parentId, let topicId):
            if target.conversationId == topicId {
                ToastCenter.shared.show(.info, "This topic was archived", nil)
                Task { await switchTargetAfterArchive(parentId: parentId) }
            }
        case .settingsUpdated(let parentId, let topicsEnabled):
            if target.parentConversationId == parentId, !topicsEnabled {
                ToastCenter.shared.show(.info, "Topics disabled by admin", nil)
                if case .topic(_, let parent) = target {
                    setTarget(.conversation(parent))
                }
            }
        default:
            break
        }
    }

    private func switchTargetAfterArchive(parentId: String) async {
        guard case .topic(_, let parent) = target else { return }
        do {
            let topics = try await APIClient.shared.fetchTopics(parentId: parent.id)
            if let general = topics.first(where: { $0.is_general }) {
                setTarget(.topic(general, parent: parent))
            } else {
                setTarget(.conversation(parent))
            }
        } catch {
            setTarget(.conversation(parent))
        }
    }
```

`@Published private(set) var target: ChatTarget` (already declared in Task 1) drives UI updates; calling `setTarget(...)` is the only mutation path.

Dedup `message:sent` vs `topic:message`. In the `onMessageSent` handler (existing — `SocketClient.shared.onMessageSent`):

```swift
    SocketClient.shared.onMessageSent = { [weak self] message in
        // If the inbound message has a topicId field, the topic:message handler
        // already routed it. Skip here to avoid duplicates.
        if message.topicId != nil { return }
        self?.ingestRealtimeMessage(message)
    }
```

This requires `Message` to expose a `topicId` field. **`Message` has explicit `init(...)`, `init(from:)` (decoder), `enum CodingKeys`, and `encode(to:)`** (Models.swift:166–319). Adding `topicId` requires four edits:

1. Add the stored property `let topicId: String?` near the other `let` fields.
2. Add `case topicId = "topicId"` to `enum CodingKeys`.
3. Update the explicit memberwise init at Models.swift:204 — append `topicId: String? = nil` parameter and `self.topicId = topicId` body line.
4. Update `init(from:)` at Models.swift:238 — `self.topicId = try? c.decodeIfPresent(String.self, forKey: .topicId)`.
5. Update `encode(to:)` (around Models.swift:302) — `try c.encodeIfPresent(topicId, forKey: .topicId)`.

BE puts `topicId` on the `data` payload of `message:sent` for topic messages (see backend `messages.service.ts:1340` — `messageSentData = { ...sentMessage, topicId: topicIdForPayload }`).

- [ ] **Step 4: Run all unit tests**

Run: `xcodebuild ... test -quiet 2>&1 | tail -30`
Expected: every test green, including the new `ChatViewModelEndpointTests`.

- [ ] **Step 5: Manual smoke**

Run the simulator. Open a topic, send a message — it appears inline. Have a second user (different device or seed via the dev BE) send a message in the same topic — it appears once (no double). Switch to a different topic via the sheet, send — message appears in the new topic and the old topic shows an unread badge.

- [ ] **Step 6: Single commit covering both Task 9 and Task 10**

```bash
git add GitchatIOS/Features/Conversations/ChatDetailView.swift \
        GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift \
        GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS/Core/Models/Models.swift \
        GitchatIOSTests/ChatViewModelEndpointTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(chat): topic-aware ChatDetailView + ViewModel endpoints + WS dedup

ChatDetailView fetches the topic list when the conversation has
topics_enabled and auto-targets the General topic. The title bar
renders 'emoji name' + 'in <group>' + chevron when a topic is
active; tapping presents TopicListSheet. Picking a different topic
calls vm.setTarget(...) which resets messages and re-fetches.

ChatViewModel.sendEndpoint and .fetchEndpoint branch on ChatTarget,
producing the parent-prefixed path for topics. message:sent vs
topic:message dedup mirrors the extension: when a topic message
arrives via topic:message the message:sent path is skipped.
ConversationsCache.patchLastMessage refreshes the parent row inline
so the conversation list does not show stale activity. Active topic
archive auto-switches to General (or .conversation if no General),
matching the extension's Bug 8 handling."
```

---

## Task 11: `OutboxStore.PendingMessage` topic context

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift`

The actual struct is `OutboxStore.PendingMessage` (OutboxStore.swift:62), and the codebase uses **camelCase** field naming (`conversationID`, `senderLogin`, etc.) — not snake_case. Match house style.

- [ ] **Step 1: Add `topicID` + `parentConversationID` to `PendingMessage`**

```swift
    struct PendingMessage: Identifiable, Equatable, Codable {
        // ...existing fields unchanged...
        let topicID: String?
        let parentConversationID: String?       // present iff topicID is non-nil
    }
```

Synthesized `Codable` regenerates automatically. If the struct has explicit `CodingKeys`, append `case topicID` and `case parentConversationID`. Persistence: if `OutboxStore` writes `PendingMessage` to disk via JSON, old persisted payloads (without these fields) decode fine because both new fields are optional — no migration needed.

- [ ] **Step 2: Branch the flush worker's endpoint**

Find the spot in the flush worker where it builds the send URL (likely a `private var endpoint(for: PendingMessage) -> String` or inline). Replace with:

```swift
    private func endpoint(for msg: PendingMessage) -> String {
        if let topicID = msg.topicID, let parentID = msg.parentConversationID {
            return "messages/conversations/\(parentID)/topics/\(topicID)/messages"
        }
        return "messages/conversations/\(msg.conversationID)"
    }
```

- [ ] **Step 3: Surface the topic context when enqueuing**

Find every site in `ChatViewModel` that enqueues a `PendingMessage` (the optimistic-send path). Wrap the existing `PendingMessage(...)` construction with target-aware id derivation:

```swift
    let (parentID, topicID): (String?, String?) = {
        switch target {
        case .conversation: return (nil, nil)
        case .topic(let t, let p): return (p.id, t.id)
        }
    }()
    let pending = PendingMessage(
        // ...existing keyword args...
        conversationID: target.conversationId,
        topicID: topicID,
        parentConversationID: parentID
    )
```

- [ ] **Step 4: Drop on archive 410**

In the outbox flush error handler, when the BE returns 410 Gone (via `APIError.http(410, body)` where the body contains `"TOPIC_ARCHIVED"`), drop the item and toast: `ToastCenter.shared.show(.error, "Topic was archived", "Message not sent")`. Match the existing failure-handling pattern around it.

- [ ] **Step 5: Build + commit**

```bash
xcodegen generate && xcodebuild ... build -quiet
git add GitchatIOS/Core/OutboxStore.swift \
        GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(outbox): carry topic_id + parent_conversation_id

Pending sends now know whether they target a conversation or a topic
so the flush worker uses the parent-prefixed endpoint. Archive race
(BE 410 TOPIC_ARCHIVED) drops the pending item with a toast instead
of retrying forever."
```

---

## Task 12: WS reconnect re-sync of topics

**Files:**
- Modify: `GitchatIOS/Core/Realtime/SocketClient.swift` (small hook)
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift` or `ChatDetailView.swift`

- [ ] **Step 1: Add a reconnect callback**

Find `SocketClient.onConnect` (the `socket.on(clientEvent: .connect)` block at line ~80 of `SocketClient.swift`). Add an optional public callback alongside:

```swift
    var onReconnect: (() -> Void)?
```

Inside the `.connect` handler, after the existing re-subscribe logic, call the new hook on the main actor:

```swift
        // ...existing re-subscribe loop...
        Task { @MainActor in self?.onReconnect?() }
```

- [ ] **Step 2: Re-fetch topics on reconnect inside `ChatDetailView`**

Add a reconnect handler that re-fetches topics for the active parent:

```swift
    @State private var reconnectObserver: NSObjectProtocol?

    private func attachReconnectObserver() {
        // hook SocketClient.shared.onReconnect — single-callback contention is fine
        // here because no other consumer cares about reconnect for this purpose.
        SocketClient.shared.onReconnect = { [weak self] in
            Task { @MainActor in
                guard let self,
                      case .topic(_, let parent) = self.resolvedTarget else { return }
                if let fresh = try? await APIClient.shared.fetchTopics(parentId: parent.id) {
                    TopicListStore.shared.setTopics(fresh, forParent: parent.id)
                }
            }
        }
    }
```

Call `attachReconnectObserver()` from `.task(id: conversation.id)` and clear `SocketClient.shared.onReconnect = nil` from `.onDisappear`. (The single-callback model is fine because no other view sets it today; if a second consumer arrives later, refactor to NotificationCenter.)

- [ ] **Step 3: Manual smoke**

Open a topic in the simulator. Toggle airplane mode for ~5 seconds, restore. The list should re-fetch and any missed events (e.g. a new topic added during the offline window) should appear.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Core/Realtime/SocketClient.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(realtime): re-fetch topics on WS reconnect

Diff-via-replace: SocketClient.onReconnect re-fires fetchTopics for
the parent of any active topic; setTopics replaces the cached list.
Avoids missed topic:created / topic:archived events during the
offline window. Same pattern Slug uses for conversations re-sync."
```

---

## Task 13: Final build + manual test plan walkthrough

**Files:** none (verification only).

- [ ] **Step 1: Clean build**

Run:
```bash
xcodegen generate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  clean build -quiet
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run the full unit-test suite**

Run: `xcodebuild ... test -only-testing:GitchatIOSTests -quiet 2>&1 | tail -30`
Expected: all topic-related tests pass.

- [ ] **Step 3: Run UI tests (regression)**

Run: `xcodebuild ... test -only-testing:GitchatIOSUITests -quiet 2>&1 | tail -30`
Expected: existing UI tests still green. The `ChatViewModel(conversation:)` convenience init keeps every legacy call site compiling, so UI tests should not need changes.

- [ ] **Step 4: Walk the spec §8.2 manual test plan**

Use the dev backend (`api-dev.gitstar.ai`, `ws-dev.gitstar.ai`). Two test users — one admin, one member — in a group with `topicsEnabled=true` and at least General + 2 other topics.

Tick each scenario from spec §8.2 (1–13). For each scenario, the expected behavior is described in the spec; mark fail/pass and capture screenshots / logs for any failure.

- [ ] **Step 5: Update Vincent's contributor log**

After local verification + per the cross-project workflow rule, update [gitchat_extension/docs/contributors/vincent.md](../../../../gitchat_extension/docs/contributors/vincent.md) — Current section overwrites with today's branch + task; Decisions appends one line with the topic feature ship summary. **Commit that change in the gitchat_extension repo separately** (different repo, can't be one commit). Do this *after* the iOS PR is opened, not during this branch's work.

- [ ] **Step 6: Open PR (only after user approval)**

Per the iOS issue-fix workflow, do not open the PR until the user has confirmed the manual test plan passes locally. When approved:

```bash
git push -u origin <branch>
gh pr create --title "feat(ios): topic feature — list / create / pin / archive" \
             --body "$(cat <<'EOF'
## Summary

Implements the iOS topic feature in parity with the VS Code extension UX,
layered on Slug's PR #89 chat foundation.

- Distinct Topic struct + ChatTarget enum drive the existing ChatViewModel
  via branched send/fetch endpoints (no parallel ViewModel).
- TopicListSheet + TopicCreateSheet for browsing and creating.
- 12 emoji presets + 8 colorset assets (Apple HIG palette, light/dark).
- Realtime: subscribe to parent room only; 7 v1 topic events handled
  (created, updated, archived, pinned, unpinned, settings-updated, message).
- message:sent vs topic:message dedup mirrors the extension behavior.
- ConversationsCache.patchLastMessage freshens the parent row on
  topic:message without a REST round-trip.
- WS reconnect re-fetches topics for the active parent.

Spec: docs/superpowers/specs/2026-04-28-ios-topic-feature-design.md
Plan: docs/superpowers/plans/2026-04-28-ios-topic-feature-plan.md

## Out of scope (deferred)

Rename / unarchive / delete / close-reopen / hide-general / per-user
permissions UI / settings panel / search / optimistic create / deep
links / topic_id push payload routing / client-side role tracking.

## Test plan

- [ ] xcodebuild ... test passes (GitchatIOSTests + GitchatIOSUITests)
- [ ] Manual scenarios 1–13 from spec §8.2 pass on iPhone 15 simulator
- [ ] Manual scenarios pass on Catalyst (sheet renders as floating panel)
- [ ] Dark mode contrast verified for all 8 colorsets
EOF
)"
```

- [ ] **Step 7: No commit needed for Step 1–4 (verification-only)**.

---

## Notes for the executing engineer

- **DRY:** `TopicEndpoints` is the single source of truth for topic URL strings. Resist the urge to inline paths inside `APIClient+Topic.swift` — having them as static functions makes Task 4's tests feasible.
- **YAGNI:** Eight BE features are explicitly out of scope (spec §1.2). Don't add Cancel buttons / settings sliders / search bars. If a teammate asks "while we're here", say no and link the spec.
- **TDD:** Every pure-logic unit (model decode, store mutations, endpoint URLs, color resolver, socket payload decoders, view-model branching) ships with a failing-first test. Views are smoke-tested in the simulator since the repo has no SwiftUI snapshot harness.
- **Frequent commits:** One per task is the floor. If a task feels too big to commit at once, split it (e.g. Task 7 could land TopicRow first, then TopicListSheet). The plan groups them for readability, not to mandate a single commit.
- **Verification before completion:** Apply `superpowers:verification-before-completion` before claiming any task done. Build + run tests + watch the simulator for the relevant scenario before checking the box.
- **DESIGN.md compliance:** Every spacing value used (8, 12, 16, 24, 32, 36, 44, 60) is on the 4/8pt grid. Touch targets ≥44pt are noted explicitly. Semantic SwiftUI fonts (`.headline`, `.subheadline`, `.footnote`, `.caption`, `.title3`) — never `.system(size:)`. No hardcoded hex.
- **Reuse:** `Skeleton`, `Toast`, `GroupAvatarView`, `RelativeTime`, `GlassPill`, `MacRowStyle` — all exist in `Core/UI/`. Use them; do not re-implement. If a sheet pattern feels novel, check `PinnedMessagesSheet`, `MembersSheet`, `EmojiPickerSheet`, `GroupSettingsSheet`, `ForwardSheet`, `ImageCropSheet` first.

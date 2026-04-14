# Gitchat iOS Native

Native SwiftUI port of the [Gitchat VS Code extension](https://github.com/GitchatSH/gitchat_extension).
Bundle ID `git.chat`, iOS 16+, shares the same backend as the extension
(`api-dev.gitstar.ai`, `ws-dev.gitstar.ai`) so your IDE and phone stay in lock-step.

See the [Releases](https://github.com/GitchatSH/gitchat-ios-native/releases)
page for per-build notes; builds `10` through `18` cover the big refactor
pass (messaging features, push, realtime, UX polish).

## Quick start

```bash
brew install xcodegen
xcodegen generate
open GitchatIOS.xcodeproj
```

CLI build:
```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Install on a paired device (wireless debugging must be on):
```bash
xcrun devicectl device install app --device <device-udid> \
  ~/Library/Developer/Xcode/DerivedData/GitchatIOS-*/Build/Products/Debug-iphoneos/GitchatIOS.app
```

TestFlight archive + upload:
```bash
xcodebuild archive -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS' -archivePath build/GitchatIOS.xcarchive \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/GitchatIOS.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```

## Project layout

```
GitchatIOS/
├── App/              # GitchatApp entry, RootView, MainTabView
├── Core/
│   ├── Config.swift  # apiBaseURL, wsURL, userAgent, etc.
│   ├── Networking/   # APIClient, envelope decoding, multipart upload
│   ├── Realtime/     # SocketClient (Socket.IO client)
│   ├── Models/       # Codable DTOs (Message, Conversation, UserProfile, ...)
│   ├── StoreKit/     # StoreManager — IAP: Gitchat Pro subscription
│   ├── BlockStore.swift
│   ├── PushManager.swift
│   └── UI/           # Toast, Haptics, Skeleton, RelativeTime
├── Features/
│   ├── Auth/         # SignInView, GitHubWebOAuth, LinkGithubBanner, SafariSheet
│   ├── Conversations # ConversationsListView, ChatDetailView, NewChatView
│   ├── Channels/     # ChannelsView, ChannelDetailView
│   ├── Following/    # FollowingView (Friends tab)
│   ├── Notifications # Activity tab
│   ├── Pro/          # UpgradeView
│   └── Profile/      # ProfileView, MeView, SettingsView
├── Resources/
│   ├── Assets.xcassets (AppIcon, AppLogo, LaunchIcon, GitHubMark)
│   └── Geist fonts
└── Info.plist
```

## Features implemented

### Auth
- GitHub OAuth via embedded web flow + Sign in with Apple fallback.
- `LinkGithubWall` when a signed-in user hasn't linked GitHub yet.
- Sign-out confirmation (centered alert).
- System star rating prompt ~2 s after successful sign-in.

### Chats (Conversations)
- **List**: pinned-first sort, search bar, skeleton loading,
  row separators hidden to match Channels/Friends.
- **Swipe actions**: right = pin/unpin (orange), left = delete (red).
- **Long-press context menu**: Pin/Unpin, Mute/Unmute, Delete (red icon + text).
- **Delete** (swipe or menu) asks for confirmation via a SwiftUI alert.
- **New chat sheet**: searchable user picker, existing friend list as default
  suggestions. "New Group" text button creates a group; tapping Create opens a
  SwiftUI alert that prompts for the group name.

### Chat detail
- **Run grouping**: consecutive messages from the same sender collapse avatar +
  name after the first bubble.
- **System messages** ("joined", "left", "pinned a message", "renamed the
  group", etc.) render as a centered secondary-label capsule instead of a
  normal bubble.
- **Native context menu** (long-press) with React / Reply / Copy / Pin /
  Forward / Edit / Unsend / Delete / Report. Destructive items are red (icon
  + text). Long-press only zooms the bubble, not the avatar + name row.
- **React**: opens a full 48-emoji `EmojiPickerSheet` (360pt detent). Picking
  is optimistic — the chip updates on the bubble instantly. Double-tap any
  bubble to react ❤️.
- **Reply**: tapping Reply auto-focuses the composer. Reply preview above a
  bubble is tappable — scrolls to the original message and triggers a subtle
  scale pulse on the target.
- **Pinned state**: bubbles show a small pin indicator when pinned. Menu flips
  between Pin and Unpin based on the locally-tracked `pinnedIds` set.
- **Forward**: picker sheet with multi-select conversation list, posts the
  message to every selected chat.
- **Unsend / Delete**: confirm via SwiftUI alert before firing; unsent
  messages render as a muted "Message unsent" bubble.
- **Edit**: `editMessage` PATCH; draft restored into composer with an
  "Editing" banner.
- **Reactors bottom sheet**: horizontal emoji tab strip (All N, then per
  emoji), tapping a row pushes that user's profile.
- **Attachments**: multi-image picker (up to 10). Images are compressed to
  1600px max edge, JPEG 0.75, uploaded in parallel via `TaskGroup`. An
  optimistic `file://` bubble renders immediately and is swapped for the
  server message on success.
- **Image viewer**: tap any attachment → full-screen `ImageViewerSheet` with
  paged `TabView`, pinch-to-zoom + double-tap zoom.
- **Toolbar ellipsis menu**: View profile (DM) / N Members (group), Search,
  Pinned messages, Mute/Unmute.
- **Search sheet**: `GET /messages/conversations/:id/search?q=`, search-as-
  you-type with debounce.
- **Pinned messages sheet**: `GET /messages/conversations/:id/pinned-messages`.
- **Members sheet**: group participants list, tapping a row pushes their
  profile.
- **Composer**:
  - Three glass capsules — white paperclip, transparent capsule text field,
    solid accent circular send button. `.glassEffect(.regular, in: Capsule())`
    on iOS 26+, `.ultraThinMaterial` fallback.
  - Slides up with a spring on appear; tab bar hidden via
    `.toolbar(.hidden, for: .tabBar)`.
  - `@FocusState` — Reply menu action focuses the text field.
  - `@ mention autocomplete` in group chats: a horizontal participant chip
    row appears above the composer when the trailing `@token` matches.
  - Draft persisted per conversation id to `UserDefaults`.
  - Tap scroll area or swipe-dismiss to drop the keyboard.
- **Attributed bubble text**:
  - `@username` is bolded and a `gitchat://user/<login>` link; tapping opens
    that profile.
  - URLs detected via `NSDataDetector` are bolded + underlined; tapping opens
    them in an in-app `SafariSheet` via a custom `OpenURLAction` handler.
- **Reply preview quoting**, **scroll-to-bottom on open** with an invisible
  anchor + 8pt bottom spacer. Entry scroll uses
  `Transaction(disablesAnimations: true)` so the chat opens already at the
  last message with no visible scroll.
- **Tap a bubble** to reveal its relative timestamp above the bubble with a
  subtle opacity + top-slide transition. Tap again to hide.
- **Typing indicators**: composer emits `typing:start` / `typing:stop`; chat
  shows an animated glass-capsule three-dot row when others are typing.
- **Read receipts**: subtle "Seen" footer when the other side's read cursor
  covers your last sent message.

### Profile
- **Me view** with settings gear in the toolbar.
- **Self profile**: avatar, followers / following / repos, top repos, upgrade
  card (if not Pro), Pro badge (if Pro).
- **Other users**: GitHub icon button (top-right toolbar, `GitHubMark`
  asset), Follow / Following button + Chat (`paperplane.fill`) + ellipsis
  menu with Unfollow / Block / Unblock / Report.
- **Followers / Following stats** are tappable and open a `FollowListSheet`
  bottom sheet backed by `GET /followers?login=` / `GET /following?login=`.
- **Profile skeleton** while loading (`ProfileSkeleton`).
- **Follow state** decoded from `{ following, followedBy }` (CodingKeys fix
  for backend's camelCase).
- **Report** sheet with reason picker + detail field.
- **`APIClient.userProfile(login:)`** decodes the nested `{ profile, repos }`
  shape returned by `GET /user/:username` and maps to `UserProfile`.

### Settings
- Account section: signed-in-as row + **Plan** row (sparkles + Pro/Free +
  chevron).
- Appearance: theme picker, compact chat rows.
- Notifications: in-app sound, unread badges.
- Privacy & Safety: online status, autoplay GIFs, blocked users list.
- Legal: EULA / Terms / Privacy (opens in `SafariSheet`).
- About: version.
- Sign out (destructive, centered alert).

### Channels
- Searchable list (same drawer style as Chats / Friends).
- Skeleton loading state.
- Hidden row separators.
- Channel detail view (existing).

### Friends (Following)
- Searchable list, skeleton loading, hidden separators.
- Tap a row to push that user's profile.

### Activity (Notifications)
- List with relative timestamps ("10 min ago") via a shared `RelativeTime`
  helper wrapping `RelativeDateTimeFormatter`.
- Hidden separators, unread dot.
- Read-all toolbar action.
- Rows are tappable and route via `AppRouter`: `chat_message` / `new_message`
  / `mention` with a `conversation_id` → open the chat; `mention` / `follow`
  / `wave` / fallback → open the actor's profile. Selection haptic on tap.
- Missing actor avatars fall back to `github.com/<login>.png`.

### System UI / polish
- Global `UIScrollView.appearance()` — all scroll indicators hidden.
- Shared skeleton shimmer (`Core/UI/Skeleton.swift`) used across Chats,
  Channels, Friends, Profile, and FollowListSheet.
- Custom toast banner (`Core/UI/Toast.swift`) — dynamic-island-ish capsule
  with `.glassEffect` on iOS 26+, `.ultraThinMaterial` otherwise. Auto-sized,
  centered at top, tap to dismiss.
- Haptics sprinkled across follow/unfollow, chat create, pin/delete, forward,
  mute, report, block, double-tap react, tab change, keyboard/menu taps.
- Splash screen uses `LaunchIcon` (200/400/600 px @1x/2x/3x) centered on the
  accent color.
- Communication-style UI not yet wired end-to-end — see "Known gaps".

### Realtime (`SocketClient`)
- Socket.IO client auto-reconnect, subscribes to:
  - `user:<login>` room on app open (for conversation-level events like
    `conversation:updated`, `unread:updated`, `presence:updated`).
  - `conversation:<id>` room when a chat detail is opened.
- Events handled: `message:sent`, `conversation:updated`, `presence:updated`,
  `reaction:updated`, `notification:new`, `typing:start` / `typing:stop`,
  `conversation:read`.
- `globalOnMessageSent` fires in parallel with the view-local hook so the
  root view can show an **in-app toast banner** when a message arrives for
  a different conversation than the one you're currently viewing.
- `currentConversationId` tracks which chat is on screen so banners are
  suppressed for the active conversation.
- `emitTyping(conversationId:isTyping:)` pushes typing:start / typing:stop
  when the composer draft changes.
- Heartbeat ping every `Config.presenceHeartbeatSeconds` while authed.

### AppRouter
Shared singleton (`Core/UI/AppRouter.swift`) exposing `selectedTab`,
`pendingConversationId`, and `pendingProfileLogin`. Drives external
navigation from push clicks, activity taps, and mention links. `MainTabView`
binds to `selectedTab`; `ConversationsListView` watches
`pendingConversationId` and pushes the matching `Conversation` onto its
`NavigationPath`; `RootView` presents a `ProfileView` sheet for
`pendingProfileLogin`.

### StoreKit / Pro
- `StoreManager` — Gitchat Pro auto-renewing subscription product.
- Upgrade sheet (`UpgradeView`) accessible from settings and the profile card.
- `isPro` drives the active/inactive rendering of the Plan row and the Pro
  badge on the profile.

### Push notifications
- OneSignal v5 SDK integrated via `OneSignalXCFramework` SPM.
- Notification Service Extension (`OneSignalNotificationServiceExtension`)
  registered, app group `group.chat.git.onesignal` configured, and
  `com.apple.developer.usernotifications.communication` entitlement enabled.
- **Communication Notifications**: the NSE donates an `INSendMessageIntent`
  with a downloaded sender avatar and calls
  `UNNotificationContent.updating(from:)`, so pushes render with the
  sender's avatar as the hero + the app icon as a small corner badge on
  iOS 15+. NSE links `Intents.framework` via xcodegen
  `sdk: Intents.framework`.
- **Deep-link routing**: `PushManager` registers an
  `OSNotificationClickListener` that drives `AppRouter`:
  - `chat_message` / `group_add` / `reply` → open conversation
  - `mention` with `conversation_id` → open conversation
  - `mention` / `follow` without one → open actor profile
  - everything else → switch to the Activity tab
- Backend push parity: a shared helper `src/shared/push/push.ts` (typed
  `PushType` + `PushData` payload) sends pushes on follow, event_like,
  repo_starred, event_comment, mention, post_like, post_reply, and reply
  mentions — alongside the existing chat message push.

## Known gaps / next pass

- Backend push senders still missing for group add-member, awesome-list
  milestones, and pin-message broadcasts (helper is in place, just not
  wired at those call sites).
- MVVM file split — `ChatDetailView.swift` is still monolithic (~1800 lines).
- Multi-file document attachments (only images today).
- Global message search (cross-conversation).
- Typing indicators (`typing:start` / `typing:stop` already emitted by
  backend; just needs UI).
- Read receipts rendering (`otherReadAt` already returned by the backend).
- MVVM file split — `ChatDetailView.swift` is still monolithic (~1500 lines).
- Trending / For-You feed, wave-at-user, channel auto-join + feed posts,
  profile README badge — parity items with the extension.

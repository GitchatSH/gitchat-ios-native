# Gitchat iOS Native — Walkthrough

SwiftUI rewrite of the Gitchat browser/VS Code extension, built from scratch in Swift
targeting iOS 16+ (with iOS 17+ niceties gated behind `#available`). Bundle ID `git.chat`,
Team `9S5F8693FB`.

## Layout

```
gitchat-ios-native/
├── project.yml                      # xcodegen spec → GitchatIOS.xcodeproj
├── GitchatIOS/
│   ├── Info.plist
│   ├── App/
│   │   ├── GitchatApp.swift         # @main, injects AuthStore + SocketClient
│   │   └── RootView.swift           # Auth gate + MainTabView + 60s presence heartbeat
│   ├── Core/
│   │   ├── Config.swift             # API/WS URLs, GitHub OAuth client id
│   │   ├── Models/Models.swift      # Conversation, Message, UserProfile, Notification, RepoChannel, ...
│   │   ├── Networking/
│   │   │   ├── AuthStore.swift      # Keychain-backed token store
│   │   │   └── APIClient.swift      # Typed async endpoints for the full backend surface
│   │   └── Realtime/
│   │       └── SocketClient.swift   # Socket.IO client, event handlers, subscribe/unsubscribe
│   ├── Features/
│   │   ├── Auth/
│   │   │   ├── GitHubDeviceFlow.swift   # Device-code OAuth flow (user_code, poll, token)
│   │   │   └── SignInView.swift
│   │   ├── Conversations/
│   │   │   ├── ConversationsListView.swift
│   │   │   └── ChatDetailView.swift     # Bubbles, composer, reactions, live updates
│   │   ├── Profile/
│   │   │   └── ProfileView.swift        # Self and other profiles; Me tab with sign-out
│   │   ├── Notifications/NotificationsView.swift
│   │   ├── Channels/ChannelsView.swift
│   │   └── Following/FollowingView.swift
│   └── Resources/Assets.xcassets/
│       ├── AppIcon.appiconset/      # 1024 single-size icon, orange + speech bubble
│       └── AccentColor.colorset/    # Gitchat brand orange
```

## Tech choices

| Concern        | Choice                                                       |
|----------------|--------------------------------------------------------------|
| UI             | SwiftUI, `NavigationStack`, `TabView`                        |
| Min iOS        | 16.0 (iOS 17+ API like `ContentUnavailableView` gated)       |
| Auth           | GitHub OAuth **Device Flow**, then exchanged via `/auth/github-link` for a Gitchat token |
| Token storage  | Keychain (`kSecClassGenericPassword`, after-first-unlock)    |
| Networking     | `URLSession` + async/await; envelope-aware `APIClient`        |
| Realtime       | `socket.io-client-swift` SPM package                          |
| Presence       | 60s heartbeat loop kicked off by `RootView` after auth       |
| App icon       | Generated from CoreGraphics at build-setup time             |
| Project gen    | `xcodegen` (`project.yml` is the source of truth)            |

## Feature parity with the extension

Mirrors the VS Code extension's backend API surface:

- **Auth**: `/auth/github-link`
- **Conversations**: list / create / get messages / send / mark-read / react
- **Profile**: `/user/profile`, `/user/:login`
- **Following**: follow / unfollow / list
- **Notifications**: list / mark read (all)
- **Channels**: list
- **Presence**: heartbeat (`PATCH /presence`)

Extended endpoints (pinning, group management, message edit/delete, invites,
reactions delete, search, channel feeds) are already hooked in the model layer
and just need UI — next pass.

## Real-time sync

`SocketClient` connects to `https://ws-dev.gitstar.ai`, auto-reconnects, and
re-subscribes to open conversations on reconnect. It listens for:
- `message:sent` → append to open chat
- `conversation:updated` → refresh list
- `presence:updated` → update online dots
- `reaction:updated` → refresh reactions on message
- `notification:new` → refresh activity tab

## Build

```
brew install xcodegen
cd gitchat-ios-native
xcodegen generate
open GitchatIOS.xcodeproj
```

Or from CLI:
```
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Install on device (wifi)

```
xcrun devicectl device install app \
  --device 1624F023-B952-520F-B39A-2D1651B6E3AB \
  ~/Library/Developer/Xcode/DerivedData/GitchatIOS-*/Build/Products/Debug-iphoneos/GitchatIOS.app
```

Phone must be unlocked and paired for wireless debugging in Xcode
(Window → Devices & Simulators → "Connect via network").

## Recent changes

- Profile: added "GitHub" and "Chat" action buttons on other users' profiles. GitHub opens `https://github.com/<login>` via `Link`; Chat calls `createConversation` and presents `ChatDetailView` in a sheet. Hidden on the self profile.
- Conversations list: hid row separators to match Channels/Friends.
- Chat detail: `.toolbar(.hidden, for: .tabBar)` hides the bottom tab bar on push, and the composer slides/fades up via a spring transition on appear.
- Profile actions refactor: top-right toolbar now shows a GitHub icon button (template-rendered `GitHubMark` asset → `https://github.com/<login>`). The row below the stats is now Follow/Following (calls `GET /follow/:login` + POST/DELETE) + Chat + a Menu (ellipsis) with Unfollow/Block/Unblock/Report. Added `APIClient.followStatus` and `reportUser`.
- Profile loading uses a shimmer skeleton (`ProfileSkeleton`) instead of a spinner.
- Global: disabled scroll indicators via `UIScrollView.appearance()` in `GitchatApp.init`.
- Conversations list: swipe right to pin/unpin, swipe left to delete. New `APIClient.pinConversation / unpinConversation / deleteConversation`.
- Chat detail composer: removed the divider, rounded the text field into a full capsule, and wrapped the bar with `.glassEffect(.regular, in: Capsule())` on iOS 26+ (ultraThinMaterial fallback on older systems).
- Profile: fixed follow button — `FollowStatus` now decodes backend `followedBy` via CodingKeys (was failing to decode and leaving the button disabled). Chat button uses `paperplane.fill`. Dropdown buttons no longer use the destructive role and the Menu runs in a forced-dark color scheme for uniform white labels. Spacing between Follow/Chat/ellipsis tightened to 6pt.

## Recent changes

- Settings: moved Gitchat Pro card to the top and restyled it with the same accent gradient used on the profile upgrade card (active-Pro variant now also shows the gradient).
- Settings: removed the API host row from the About section.
- Added a shared shimmer skeleton (`Core/UI/Skeleton.swift`, `SkeletonList`) and replaced spinner loading states in Chats, Channels, Friends, and the followers/following sheet.
- Channels and Friends tabs now have search bars (navigation-bar drawer) matching the Chats tab, and their list row separators are hidden.
- Fixed "Unable to load" on other users' profiles: `APIClient.userProfile(login:)` now decodes the nested `{ profile, repos }` response shape returned by `GET /user/:username` and maps it into `UserProfile`.
- Profile followers/following stats are now tappable and open a bottom sheet (`FollowListSheet`) listing users via `GET /followers?login=` and `GET /following?login=`.

## Known gaps / next pass

- Image / file attachments in composer
- Message editing, deletion, pinning UI (API is wired)
- Group creation and invite flow
- Channel feed (X / YouTube / Gitchat posts) inside channel detail
- Push notifications (APNs registration)
- Dark-mode polish pass on chat bubbles
- iOS 16 fallback tested in simulator only — verify on real iOS 16 hardware if possible

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

## Known gaps / next pass

- Image / file attachments in composer
- Message editing, deletion, pinning UI (API is wired)
- Group creation and invite flow
- Channel feed (X / YouTube / Gitchat posts) inside channel detail
- Push notifications (APNs registration)
- Dark-mode polish pass on chat bubbles
- iOS 16 fallback tested in simulator only — verify on real iOS 16 hardware if possible

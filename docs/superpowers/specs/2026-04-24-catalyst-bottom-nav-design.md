# Catalyst Bottom Navigation — Design Spec

**Date:** 2026-04-24
**Status:** Draft — pending user review
**Owner:** @nakamoto-hiru

## Goal

Add bottom navigation cho Mac Catalyst version (`SUPPORTS_MACCATALYST: YES`) để user có cách chuyển giữa 5 tab chính trên Desktop. Hiện tại trên Catalyst, `TabView` của SwiftUI render không như mong đợi — user mở app Mac chỉ thấy Chats list, không có nav bar.

Reference: Telegram Desktop nav strip ở dưới sidebar.

## Why

- Trên Catalyst hiện tại, 4 trên 5 tab (Discover, Activity, Friends, Me) **không truy cập được** từ Mac app. User phải dùng phone để vào những tab này.
- Native `TabView` trên Catalyst render khác Mobile và không control được visual style đầy đủ.
- Cần 1 nav riêng đặc thù cho Desktop, vẫn share state với Mobile để deep link / push notification hoạt động nhất quán.

## Scope

### In scope
- Custom bottom navigation strip ở dưới sidebar trên Catalyst
- 5 tabs y hệt Mobile: Chats, Discover, Activity, Friends, Me
- State sync với `AppRouter.shared.selectedTab`
- Hover effect, tooltip, badge cho Activity/Chats unread
- Keyboard shortcuts `⌘1` … `⌘5`

### Out of scope
- Không đụng iOS `MainTabView` (giữ nguyên)
- Không refactor sheets, popover, chat detail UI
- Không đổi window chrome / title bar
- Không add Settings tách riêng / Search global
- Không đổi icon set hiện tại (giữ custom `ChatTabIcon` + 4 SF Symbols)

## Visual Spec

**Pattern:** "Strip" (Telegram-style) — icons-only, full-width dưới sidebar.

| Property | Value |
|---|---|
| Position | Bottom of sidebar (column 1 of NavigationSplitView) |
| Height | ~52pt |
| Padding | 8pt vertical, 6pt horizontal |
| Layout | 5 icons phân bố đều (`space-around`) |
| Divider | 1pt line trên cùng, color `Color(.separator)` |
| Background | `Color(.secondarySystemBackground)` |

### Per-icon

| Property | Value |
|---|---|
| Icon size | 22pt |
| Touch target | 36×32pt, `borderRadius: 6` |
| Default color | `.secondary` |
| Active color | `.accentColor` |
| Hover bg | `Color.primary.opacity(0.06)` (via existing `MacHover.swift`) |
| Tooltip | tab name (via existing `InstantTooltip.swift`) |

### Badge

- Activity tab: red dot 8pt nếu có unread notifications, hoặc number capsule nếu count > 0
- Chats tab: same pattern, count = total unread conversations
- Position: top-right của icon, offset `(4, -4)`

## Architecture

### Layout strategy: **Hybrid (Plan B)**

- **Tab Chats** → giữ nguyên `ConversationsListView` với NavigationSplitView của nó. `MacBottomNav` được inject vào bottom của sidebar (chat list column ~290pt).
- **Tab Discover/Activity/Friends/Me** → render full-screen (chiếm toàn window). `MacBottomNav` apply qua `.safeAreaInset(edge: .bottom)` ở bottom window.

Trade-off chấp nhận: width của bottom nav khác nhau giữa Chats (~290pt) và các tab khác (full width). Icons giữ size cố định, chỉ spacing dãn ra. Switch tab → ConversationsListView re-mount (mất scroll state) — chấp nhận, optimize sau nếu cần.

### Current state (problem)

```
RootView
└── MainTabView                          ← TabView 5 tabs (cùng cho cả iOS + Catalyst)
    ├── ConversationsListView            ← chứa NavigationSplitView bên trong (Catalyst)
    ├── DiscoverView
    ├── NotificationsView
    ├── FollowingView
    └── MeView
```

Trên Catalyst, `TabView` không render bottom tab bar; layout split view của `ConversationsListView` ép TabView phải nằm ngoài.

### Target state

```
RootView
├── #if iOS:        MainTabView          ← KHÔNG ĐỔI
└── #if Catalyst:   MacShellView         ← MỚI
                    └── NavigationSplitView
                        ├── sidebar
                        │   ├── tabContent (Chats/Discover/Activity/Friends/Me)
                        │   └── MacBottomNav     ← MỚI
                        └── detail
                            ├── ChatDetailView (nếu Chats + có conversation chọn)
                            └── ContentUnavailableCompat (placeholder cho tab khác)
```

### State management

`AppRouter.shared.selectedTab: Int` — single source of truth, share giữa Mobile (`MainTabView` binding) và Desktop (`MacShellView` + `MacBottomNav` binding). Khi update từ deep link / push notification, cả 2 platform tự động sync.

## Components

### New files

| File | LOC est. | Purpose |
|---|---|---|
| `GitchatIOS/Core/UI/MacShellView.swift` | ~120 | Catalyst-only entry. Wrap `NavigationSplitView` với 5 tab content + `MacBottomNav` ở dưới sidebar. |
| `GitchatIOS/Core/UI/MacBottomNav.swift` | ~140 | Custom strip — 5 icons với hover, tooltip, badge, active state, keyboard shortcuts. |

### Modified files

| File | Change |
|---|---|
| `GitchatIOS/App/RootView.swift` | `MainTabView()` → wrap `#if targetEnvironment(macCatalyst) MacShellView() #else MainTabView() #endif` |
| `GitchatIOS/Features/Conversations/ConversationsListView.swift` | Tách `coreBody` Catalyst branch — bỏ `NavigationSplitView` wrapper bên trong (move ra `MacShellView`). Expose `sidebar` view có thể dùng từ ngoài. |

### Unchanged

- `MainTabView` (iOS path)
- Tất cả tab content views (Discover, Notifications, Following, Me)
- `AppRouter`
- Tất cả existing Mac-specific helpers (`MacHover`, `InstantTooltip`, `MacReadableWidth`, `CatalystCloseButton`, `MacEscapeToHome`, `DesktopReturnToSend`)

## Behavior

### Tab switch
- Click icon → `AppRouter.shared.selectedTab = index` → `MacShellView` re-render với content tab mới trong sidebar
- Detail panel:
  - Tab Chats → giữ `selectedConvo` nếu có, hoặc placeholder "Select a conversation"
  - Tab khác → placeholder "Select an item from \(tabName)"
- Animation: instant, không transition (Telegram-style)

### Hover & tooltip
- Hover icon → background highlight nhẹ (`MacHover.swift`)
- Hover delay 600ms → tooltip hiện tab name (`InstantTooltip.swift`)

### Badges
- Activity: bind vào unread count từ `NotificationsViewModel` hoặc shared store
- Chats: tổng unread từ `vm.conversations` (sum unreadCount > 0)

### Keyboard shortcuts
- `⌘1` → Chats
- `⌘2` → Discover
- `⌘3` → Activity
- `⌘4` → Friends
- `⌘5` → Me
- Bind via `.keyboardShortcut("1", modifiers: .command)` trên hidden buttons trong `MacShellView`

### Initial state
- `AppRouter.shared.selectedTab` default = 0 (Chats) — không đổi behavior hiện tại

## Testing

### Manual
- `./scripts/run-sim.sh --catalyst --build` → mở Catalyst app
- Verify: nav strip xuất hiện dưới sidebar, 5 icons clickable
- Verify: switch tab → sidebar content thay đổi, detail panel update placeholder/data
- Verify: hover state, tooltip, badge
- Verify: keyboard shortcuts `⌘1–⌘5`
- Verify: deep link (push notification → tab Activity) → cả Catalyst + Mobile cùng nhảy đúng tab
- Verify: iOS không bị ảnh hưởng — chạy `./scripts/run-sim.sh "iPhone 17"` xem TabView mobile vẫn nguyên

### Edge cases
- Window quá hẹp (min 900pt theo project setup) → 5 icons vẫn fit thoải mái
- Tab Chats với conversation đang chọn → switch tab khác → switch lại Chats → conversation cũ vẫn được giữ
- Badge count = 0 → ẩn badge
- Badge count > 99 → hiển thị "99+"

## Open Questions

(Không có — anh đã confirm hết)

## Risks / Considerations

- **Refactor `ConversationsListView`** có rủi ro break Mobile nếu tách `coreBody` không cẩn thận. Mitigation: chỉ tách Catalyst branch, iOS path giữ nguyên `NavigationStack`.
- **Badge count source** — `NotificationsViewModel` chưa chắc expose unread count realtime. Có thể cần wire thêm 1 published property. Effort tăng nhẹ.
- **Keyboard shortcut conflict** — `⌘1–⌘5` có thể xung đột với chat input nếu user đang focus textfield. Cần test scope của shortcut (chỉ active khi window focus, không khi chat input focus).

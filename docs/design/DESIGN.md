# Gitchat — Design System

Tài liệu nguồn (single source of truth) cho design rules của Gitchat trên cả **iOS** và **Mac Catalyst**. Khi anything trong UI thay đổi, update file này trước khi code.

> 📌 File này chỉ chứa **rule hiện tại** (spec, HIG, pattern đã chốt). Công việc đang làm / roadmap / follow-up → `docs/design/PLANS.md`.

---

## 1. Nguyên tắc nền tảng — Apple HIG

Mặc định mọi quyết định visual đều **phải bám Apple HIG** (Human Interface Guidelines). HIG là contract giữa app của mình và OS — bám HIG = user mở app ra cảm thấy "native", không phải "another web app rebuilt in Swift".

> 📚 Reference: <https://developer.apple.com/design/human-interface-guidelines>

### 1.1 Spacing grid — 8pt

Mọi spacing value (padding, margin, gap) **phải là bội số của 4 hoặc 8**. Cho phép: `4, 8, 12, 16, 20, 24, 32, 40, 48, 56, 64`.

❌ **Cấm**: 10, 14, 18, 22, 30, 50… (off-grid)

| Tier | Use case |
|---|---|
| `4` | Tight gaps trong cùng 1 component (icon ↔ text label) |
| `8` | Standard spacing giữa elements gần nhau |
| `12` | Section dividers, row vertical padding |
| `16` | Edge padding, list horizontal padding |
| `24` | Section breaks |
| `32+` | Large vertical sections |

### 1.2 Touch target — minimum 44×44pt

Mọi element user click/tap được **phải có touch area ≥ 44×44pt** (Apple minimum). Icon nhỏ thì invisible padding wrap quanh để đạt 44pt.

### 1.3 Typography — system fonts

Dùng SwiftUI semantic fonts thay vì hardcode `.system(size: X)`. Lý do: tự respect Dynamic Type, tự adapt iOS / macOS / Catalyst.

| Token | Size | Use |
|---|---|---|
| `.largeTitle` | 34pt | Hero titles (rare in chat app) |
| `.title` | 28pt | Page titles |
| `.title2` | 22pt | Section headers |
| `.title3` | 20pt | Subsection headers |
| `.headline` | **17pt semibold** | **Row title, button labels** |
| `.body` | **17pt regular** | **Body text, chat messages** |
| `.callout` | 16pt | Buttons, secondary actions |
| `.subheadline` | **15pt regular** | **Row subtitle, preview text** |
| `.footnote` | **13pt regular** | **Meta (timestamp, count)** |
| `.caption` | 12pt | Captions, labels |
| `.caption2` | 11pt | Smallest meta (avoid on Catalyst — too small) |

### 1.4 Color — semantic + asset catalog

Không hardcode hex. Dùng:
- SwiftUI semantic: `.primary`, `.secondary`, `.tertiary`, `.accentColor`, `Color(.systemBackground)`, `Color(.separator)`
- Asset catalog colors: `Color("AccentColor")`, `Color("MutedGray")` (defined trong `Assets.xcassets`)

### 1.5 Multi-platform — `#if targetEnvironment(macCatalyst)`

Khi cần override behavior cho Desktop:
- Wrap inline `#if targetEnvironment(macCatalyst) … #else … #endif`
- HOẶC dùng helper từ `Core/UI/MacRowStyle.swift` / `Core/UI/MacHover.swift` / `Core/UI/InstantTooltip.swift`

iOS path PHẢI giữ behavior cũ — không break Mobile khi polish Desktop.

---

## 2. Sidebar Row Spec (Mac Catalyst)

Áp dụng cho **mọi row** trong sidebar Catalyst: Chats, Discover (People/Teams/Communities), Friends, Activity. Source of truth: `GitchatIOS/Core/UI/MacRowStyle.swift`.

### 2.1 Layout

```
┌ 4pt ┬──────┬─ 12pt ─┬──────────────────────────┬ 4pt ┐
│     │      │        │ Title (17pt semibold)    │     │
│     │ AVA  │        │ Subtitle (15pt secondary)│ meta│ ← 12pt vertical padding top
│     │ 44pt │        │ Preview (15pt secondary) │ 13pt│
│     │      │        │                          │     │ ← 12pt vertical padding bottom
└─────┴──────┴────────┴──────────────────────────┴─────┘
                                                    Total row: ~68pt
```

| Property | Value | Constant |
|---|---|---|
| Avatar size | **44pt** | `macRowAvatarSize` |
| Avatar ↔ text gap | 12pt | inline `HStack(spacing: 12)` |
| Horizontal padding (inside row) | **16pt** — `macRowListContainer()` strips List's outer margin (0pt) → row padding alone provides the column inset. Active bg fills cell width minus 4pt | `macRowHorizontalPadding` |
| Vertical padding | **12pt** (top + bottom) | `macRowVerticalPadding` |
| Text vertical gap (title↔subtitle) | 2pt | inline `VStack(spacing: 2)` |
| Total row height | ~68pt | (avatar 44 + 12×2 padding) |

**Rule**: dùng **System List default margin** (~16pt) để tự align với search bar / nav title bar phía trên. KHÔNG override List container margins, KHÔNG add padding horizontal trong row. Quá trình:
1. `.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))` — reset internal row insets về 0
2. `.listStyle(.plain)` — System tự supply outer horizontal margin
3. `.macRowListContainer()` — currently no-op, hook reserved cho future tweaks (ví dụ thay đổi contentMargins)

### 2.2 Typography

| Element | Font | Color | Constant |
|---|---|---|---|
| Title | `.headline` (17pt semibold) | `.primary` | `macRowTitleFont` |
| Subtitle / preview | `.subheadline` (15pt) | `.secondary` | `macRowSubtitleFont` |
| Meta (time, date) | `.footnote` (13pt) | `.secondary` / `.tertiary` | `macRowMetaFont` |

### 2.3 Divider

**Không dùng divider giữa các row.** Rows tách biệt bằng vertical padding (12pt × 2 = 24pt breathing) + rounded active/pinned background làm visual separator.

- `.listRowSeparator(.hidden)` trên tất cả rows
- `.macRowListContainer()` hide top/bottom section separators cũng

Pattern: match Telegram Desktop / Messages macOS — card-style rows thay vì divider-style rows.

### 2.4 List container

```swift
List(items) { item in
    RowView(item)
        .listRowSeparator(.hidden)
        #if targetEnvironment(macCatalyst)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        #endif
}
.listStyle(.plain)
.macRowListContainer()  // hides top/bottom section separators on Catalyst
```

### 2.5 Active state (ConversationRow only)

Khi row ứng với conversation đang hiển thị trong detail panel (Catalyst sticky detail):

| Element | Active state |
|---|---|
| Background shape | `RoundedRectangle(cornerRadius: 10)` inset 4pt horizontal, 2pt vertical từ cell edge |
| Background fill | `Color("AccentColor")` (brand primary — orange) |
| Title text | `.white` |
| Subtitle / preview / meta | `.white.opacity(0.85)` |
| Pin/mute icons | `.white.opacity(0.85)` |
| Unread badge bg | `.white` |
| Unread badge text | `Color("AccentColor")` (inverted) |

Pinned (không active): same shape nhưng fill = `Color("AccentColor").opacity(0.08)`, text giữ default.

### 2.6 iOS fallback

Trên iOS (non-Catalyst), helpers tự fallback về defaults cũ:
- Avatar: 40pt (Discover/Activity) hoặc 56pt (Chats — Telegram-clone, updated from 50pt)
- Subtitle: `.caption` (12pt)
- Meta: `.caption2` (11pt)
- Padding: theo từng row hiện tại

→ Không break Mobile khi polish Desktop.

---

## 3. Bottom Navigation (Mac Catalyst)

Source of truth: `GitchatIOS/Core/UI/MacBottomNav.swift`.

### 3.1 Container

| Property | Value |
|---|---|
| Style | Floating capsule pill |
| Background | `.glassEffect(.regular)` (iOS 26+ Tahoe) → `.ultraThinMaterial` fallback |
| Shape | `Capsule(style: .continuous)` |
| Shadow | `radius: 12, y: 4, opacity: 0.08` |
| Outer padding | 0pt horizontal (pill tự float), 12pt bottom, 8pt top |
| Inner padding | 6pt all sides |

### 3.2 Per icon

| Property | Value |
|---|---|
| Touch target | 60×44pt (Apple min 44pt) |
| Icon size | 28pt SF Symbol / 30pt custom asset |
| Active background | `Capsule()` filled `.accentColor.opacity(0.14)` |
| Active tint | `.accentColor` |
| Inactive tint | `.primary.opacity(0.75)` |
| Hover | `MacHover.swift` modifier (`.hoverEffect(.highlight)`) |
| Tooltip | `InstantTooltip.swift` modifier — `.subheadline` (15pt) |

### 3.3 Icon set

Match Mobile MainTabView 1:1. Tất cả dùng **fill version** cho cả active/inactive (chỉ khác màu + background).

| Tag | Title | Icon |
|---|---|---|
| 0 | Chats | custom asset `ChatTabIcon` |
| 1 | Discover | `safari.fill` |
| 2 | Activity | `bell.fill` |
| 3 | Friends | `person.2.fill` |
| 4 | Me | `person.crop.circle.fill` |

### 3.4 Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘1`–`⌘5` | Switch tab Chats / Discover / Activity / Friends / Me |
| `Esc` | Back out của detail panel — clear `selectedProfile` trước (nếu đang preview profile), rồi `selectedConversation` |

---

## 4. Glass / Material — backwards compat

Project deployment target = **iOS 16.0** → Mac Catalyst chạy từ **macOS Ventura (13)** trở lên.

Pattern khi dùng glass effect:

```swift
if #available(iOS 26.0, *) {
    content.glassEffect(.regular, in: shape)   // Tahoe liquid glass
} else {
    content.background(.ultraThinMaterial, in: shape)  // frosted glass cũ
}
```

→ User trên macOS cũ vẫn thấy glass background, không bị vỡ layout.

Existing helper: `GitchatIOS/Features/Conversations/ChatDetail/GlassPill.swift` — dùng pattern này cho rounded rectangle pills. `MacBottomNav` dùng pattern tương tự cho capsule.

---

## 5. Layout — NavigationSplitView (Catalyst only)

Source of truth: `GitchatIOS/Core/UI/MacShellView.swift`.

### 5.1 Pattern: Telegram Desktop (sticky detail panel)

- **Sidebar** (~280–420pt, ideal 320pt) — nội dung swap theo `selectedTab`:
  - Chats → ConversationsListView
  - Discover → DiscoverView
  - Activity → NotificationsView
  - Friends → FollowingView
  - Me → MeView
- **Detail panel** — luôn show selected chat (sticky), **không reset khi switch tab**.
- **Bottom nav pill** — float ở bottom của sidebar, share state qua `AppRouter.selectedTab`.

### 5.2 Window

| Property | Value |
|---|---|
| Min size | 900×600pt (project.yml) |
| Sidebar column width | min 280, ideal 320, max 420pt |
| Sidebar toggle | hidden (always visible) |

### 5.3 Detail routing — state-driven (Catalyst only)

**Rule**: trên Catalyst, **không dùng `NavigationLink`** để điều hướng từ sidebar row → detail panel. Dùng state trong `AppRouter`.

**Lý do**: `NavigationSplitView` có một NavigationStack ẩn của riêng nó cho detail column. Khi `NavigationLink` trong sidebar push một view (ví dụ `ProfileView`), view đó đi vào stack ẩn này — **không nằm trong `NavigationStack` mà mình bọc ngoài**. Hậu quả:

- `.id()` trên wrapper không reset được stack ẩn
- Switch tab → sidebar đổi nhưng ProfileView vẫn kẹt trong detail panel

**Pattern đúng**:

```swift
// AppRouter.swift
@Published var selectedConversation: Conversation? = nil {
    didSet { if selectedConversation != nil { selectedProfile = nil } }
}
@Published var selectedProfile: String? = nil
@Published var selectedTab: Int = 0 {
    didSet { if oldValue != selectedTab { selectedProfile = nil } }
}

// Sidebar row (Catalyst):
Button { router.selectedProfile = user.login } label: { ... }
    .buttonStyle(.plain)

// Mobile row (iOS):
NavigationLink { ProfileView(login: user.login) } label: { ... }

// MacShellView detailPanel — priority: profile > conversation > placeholder
if let login = router.selectedProfile {
    ProfileView(login: login)
} else if let convo = router.selectedConversation {
    ChatDetailView(conversation: convo)
} else {
    placeholder
}
```

**Behavior**:
- Tab switch → `selectedProfile` auto-clear (transient browsing)
- Chọn conversation → `selectedProfile` auto-clear (chat wins focus)
- Chọn profile khác → replace `selectedProfile`
- `Esc` → clear profile trước, rồi conversation

iOS không dùng pattern này — giữ `NavigationLink` thông thường.

---

## 6. Khi nào KHÔNG dùng Catalyst-specific override?

Nếu visual logic identical giữa iOS và Catalyst → **dùng SwiftUI default**, không wrap `#if`.

Examples KHÔNG cần override:
- Standard buttons (`.buttonStyle(.bordered)`, `.borderedProminent`)
- Sheets, alerts
- Color scheme adaptation (auto-handle dark mode)

Examples CẦN override (đã có pattern):
- Row layout (avatar size, padding) → `MacRowStyle.swift`
- Hover state → `MacHover.swift`
- Tooltip → `InstantTooltip.swift`
- Keyboard shortcut Return-to-send → `DesktopReturnToSend.swift`
- Window-level overlays (sheet close button) → `CatalystCloseButton.swift`

---

## 7. Change log

| Date | Change | Author |
|---|---|---|
| 2026-04-24 | Initial — Catalyst row spec, bottom nav pill, Apple HIG rules | @nakamoto-hiru |
| 2026-04-24 | Add §5.3 state-driven detail routing (fix stale ProfileView after tab switch); Esc now backs out profile → conversation | @nakamoto-hiru |
| 2026-04-24 | Tách work notes / roadmap sang `PLANS.md` — DESIGN.md thuần spec | @nakamoto-hiru |

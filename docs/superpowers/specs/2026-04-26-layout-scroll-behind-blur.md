# Sub-project 1: Layout Architecture — Scroll-behind Blur

## Goal
Messages scroll BEHIND frosted nav bar and composer overlay (Telegram-style). No opaque backgrounds.

## Approach
UIKit contentInset on rotated UITableView. List full-screen, overlays measure themselves via GeometryReader, pass height to list for contentInset.

## Steps (implement + test each independently)

### Step 1: Nav bar blur
- `ChatDetailView.swift`: `.toolbarBackground(.ultraThinMaterial)` + `.toolbarBackground(.visible)`

### Step 2: Composer overlay
- `ChatView.swift`: Move composerStack from VStack into ZStack overlay at bottom
- `ChatInputView.swift`: Text field bg → `.ultraThinMaterial` in RoundedRectangle
- `ChatReplyEditBar.swift`: bg → `.clear`
- Measure composer height → pass to ChatMessagesList as `composerOverlayHeight`
- `ChatMessagesList.swift`: Set `contentInset.top = composerOverlayHeight` (rotated table)
- Composer background: `.ultraThinMaterial` full width, extend to safe area bottom

### Step 3: Banner overlay
- `ChatView.swift`: Move pinnedBanner from VStack into ZStack overlay at top
- Measure banner height → pass to ChatMessagesList as `bannerOverlayHeight`
- `ChatMessagesList.swift`: Set `contentInset.bottom = bannerOverlayHeight` (rotated table)

### Step 4: Scroll detection fix
- `scrollViewDidScroll`: normalize offset = `contentOffset.y + contentInset.top`
- `wasNearBottom`: same normalization
- Initial scroll: rest point = `CGPoint(x: 0, y: -contentInset.top)`
- Sync contentInset in `updateUIView` when overlay heights change

## Design System compliance
- 8pt grid spacing
- GlassPill/GlassCircle for glass effects
- 44pt touch targets
- Semantic colors + asset catalog

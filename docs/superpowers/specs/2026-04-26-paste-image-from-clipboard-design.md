# Paste Image from Clipboard — Design

**Date:** 2026-04-26
**Status:** Design — pending implementation
**Owner:** ethanmiller0x

## Problem

User on iOS / Mac Catalyst expects to paste an image from the system
clipboard into the chat composer (Cmd+V on Catalyst / iPad keyboard,
long-press → Paste on iOS). Today the app surfaces clipboard images via
a "ChatClipboardChip" suggestion bar above the composer, but:

- The chip pattern is rare in mainstream chat apps (iMessage, Telegram,
  Slack, WhatsApp, Discord all rely on the OS-level Paste action, none
  show a clipboard suggestion chip).
- `ClipboardWatcher` polls `UIPasteboard` on `didBecomeActive` and
  `changedNotification`, which on iOS 14+ triggers the system "Pasted
  from <app>" privacy banner on every read. This makes the chip both
  intrusive and unreliable across app-switch boundaries.
- Direct Cmd+V / long-press → Paste in the composer text field does not
  attach images today — UITextField's default `paste(_:)` only handles
  text.

## Goal

Replace the chip-based suggestion with a standard, OS-native paste
action that works on both iOS and Mac Catalyst:

- Cmd+V (with hardware keyboard) or long-press → Paste (touch) on the
  composer text field, with an image on the clipboard, opens the
  existing `ImageSendPreview` sheet pre-loaded with the pasted image.
- Text-only clipboard pastes into the composer as today (default
  behavior).
- Image+text clipboard pastes only the text (matches Telegram).

## Non-goals

- Multi-image paste from a single Cmd+V (e.g. Finder multi-select).
  Take only the first image. The PhotosPicker flow remains the path for
  multiple images.
- Animated GIF preservation. `UIPasteboard.general.image` decodes to
  `UIImage`, losing animation. Acceptable for v1; matches Telegram
  desktop.
- Paste into fields outside the chat composer (group name, profile bio,
  search). Default UIKit behavior is unchanged.
- Caption + image as a single message. Existing drop/picker flow sends
  caption text and image as two separate messages; paste flow inherits
  this and does not change the message model.

## Architecture

```
ChatInputView (SwiftUI)
└── PasteableTextField (UIViewRepresentable)
    └── PasteableUITextView : UITextView
         overrides:
         - canPerformAction(.paste, withSender:)
         - paste(_:)

         emits:
         - onPasteImage(UIImage) closure
                ↓
ChatView / ChatDetailView handler
                ↓
   pendingDropImages = [img]
   dropCaption = ""
   showDropConfirm = true   ← reuses existing drop flow
                ↓
   ImageSendPreview sheet (existing)
                ↓
   sendDroppedImages() (existing)
                ↓
   ChatViewModel.uploadImagesAndSend (existing)
```

The text field is the only new component. Everything from
`pendingDropImages` onward is the existing drop pipeline. Paste is
modelled as "drop with one image", not as a parallel flow.

## Components

### 1. New: `PasteableUITextView : UITextView`

Subclass of `UITextView` that overrides paste to fire a callback when
the clipboard holds an image-only payload.

```swift
final class PasteableUITextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, !pb.hasStrings, let img = pb.image {
            onPasteImage?(img)
            return
        }
        super.paste(sender)
    }
}
```

`canPerformAction` only forces Paste on for image-bearing clipboards;
for everything else it defers to `UITextView`'s default judgment so
that text, attributed text, URL, and RTF cases keep their stock
behavior.

Behavior table:

| Clipboard contents | Effect |
|---|---|
| Image only | `onPasteImage(img)` fires; no text inserted. |
| Text only | `UITextView` default paste inserts text. |
| Image + text | `UITextView` default paste inserts text; image ignored. |
| Empty | `canPerformAction` returns `false`, Paste menu hidden, Cmd+V is a no-op. |

### 2. New: `PasteableTextField : UIViewRepresentable`

Replaces `CatalystPlainTextField` (currently Catalyst-only). Used on
both iOS and Mac Catalyst. Wraps `PasteableUITextView`. Responsibilities:

- Render placeholder ("Message" / "Edit message" / "Reply…"). UITextView
  has no native placeholder — render a `UILabel` overlaid in the
  coordinator, hidden when text is non-empty.
- Auto-grow height between 1 and 5 lines on iOS (matches the current
  SwiftUI `lineLimit(1...5)`). Catalyst pins to single line for the
  floating pill layout.
- Send-on-Return on Catalyst: in `textView(_:shouldChangeTextIn:replacementText:)`,
  detect bare `\n` (Shift not held) and call `onSubmit` instead of
  inserting newline. Shift+Return inserts newline.
- Suppress macOS focus ring on Catalyst. `UITextField.focusEffect = nil`
  was the working hack today. `UITextView` inherits `focusEffect` from
  `UIView` (iOS 15+) so the same setter is available, but the rendering
  path differs and the ring may still appear via the system text-input
  context. **Implementation risk** — if `focusEffect = nil` proves
  insufficient on Catalyst, fall back to overriding
  `didUpdateFocus(in:with:)` to no-op the update animation, or wrap the
  text view in a host `UIView` whose `focusGroupIdentifier` opts out of
  the system focus engine. Verify visually on first build.
- Bridge `FocusProxy.setter` to first-responder calls (same pattern as
  current `CatalystPlainTextField`).

API:

```swift
struct PasteableTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: (UIImage) -> Void
    let focusProxy: ChatInputView.FocusProxy
}
```

### 3. Modified: `ChatInputView.swift`

- Remove `#if targetEnvironment(macCatalyst)` branching in `textField`.
  Use `PasteableTextField` for both platforms.
- Drop the SwiftUI `TextField(axis: .vertical, lineLimit: 1...5)` path.
  Multi-line behavior moves into `PasteableUITextView`.
- Add `onPasteImage: (UIImage) -> Void` to the view's API and wire it
  through to `PasteableTextField`.

### 4. Modified: `ChatView.swift` / `ChatDetailView.swift`

- `ChatInputView` now requires `onPasteImage`. Wire it to a handler
  that sets:
  ```swift
  pendingDropImages = [image]
  dropCaption = ""
  showDropConfirm = true
  ```
  Guard with `if !showDropConfirm` so a second paste while the sheet is
  already open is a no-op rather than overwriting state.
- Remove `@StateObject var clipboardWatcher = ClipboardWatcher()` and
  the `ChatClipboardChip` overlay that consumes it.

### 5. Deleted

- `GitchatIOS/Features/Conversations/ChatDetail/ClipboardWatcher.swift`
- `GitchatIOS/Features/Conversations/ChatDetail/Input/ChatClipboardChip.swift`
- References, all to remove:
  - `ChatDetailView.swift:63` — `@StateObject private var clipboard = ClipboardWatcher()`
  - `ChatDetailView.swift:147` — binding setter referencing the watcher
  - `ChatDetailView.swift:332` — `ClipboardWatcher.markSelfOriginWrite()`
  - `ChatDetailView.swift:649,654` — comment + `markSelfOriginWrite()`
    call in the "Copy Image" path
  - `ChatView.swift:261` — `ChatClipboardChip(...)` overlay
- The `markSelfOriginWrite()` calls existed to suppress the polling
  watcher's self-detection. With the watcher removed, suppression is
  no longer needed — the new flow only reads the pasteboard inside
  user-initiated `paste(_:)`, which is never self-origin.
- Final verification: `grep -rn "ClipboardWatcher\|ChatClipboardChip" GitchatIOS/`
  returns no matches.

### 6. New: UI test target `GitchatIOSUITests` (project.yml)

Add target via xcodegen. See Testing.

## Data flow

User Cmd+V on Catalyst with a screenshot on the clipboard:

1. UIKit dispatches paste through the responder chain to
   `PasteableUITextView.canPerformAction(.paste, _)` → returns `true`
   because `UIPasteboard.general.hasImages == true`.
2. UIKit calls `paste(_:)`. Pasteboard has `hasImages == true`,
   `hasStrings == false`, so we read `pb.image`, fire `onPasteImage`,
   and return without calling `super.paste`.
3. SwiftUI closure fires up through `PasteableTextField` →
   `ChatInputView.onPasteImage` → `ChatView` / `ChatDetailView`.
4. Handler sets `pendingDropImages = [img]`, `dropCaption = ""`,
   `showDropConfirm = true`.
5. `.sheet(isPresented: $showDropConfirm)` mounts `ImageSendPreview`
   bound to the same state the drop flow uses.
6. User edits caption (optional) and taps Send. `sendDroppedImages()`
   runs the existing pipeline: caption sent as text message (if any),
   then `vm.uploadImagesAndSend(images: [img], senderLogin: …)` sends
   the image. Optimistic message bubble appears immediately,
   reconciliation on upload completion.
7. iOS shows the system "Pasted from <source>" banner once, at the
   moment of paste. No further banners.

## Edge cases

| Case | Behavior |
|---|---|
| Empty clipboard | `canPerformAction` returns `false`. Long-press menu omits Paste; Cmd+V no-op. |
| `hasImages == true` but `pb.image == nil` (rare race) | `guard let` fails, fall through to `super.paste(sender)`. No crash. |
| Image > 10 MB after compression | Existing `uploadImagesAndSend` path emits `ToastCenter.shared.show(.error, "Upload failed", _)`. No new error UI. |
| HEIC / TIFF / GIF on clipboard | `UIPasteboard.image` decodes to flat `UIImage`. Animation lost for GIFs. v1 limitation. |
| Paste while previous sheet is open | Handler short-circuits on `showDropConfirm == true`. No state overwrite. |
| User pastes on a non-composer field (group name, search) | Field uses default UITextField/SwiftUI TextField, behavior unchanged. |
| Composer has draft text + user pastes image-only clipboard | Sheet opens with empty `dropCaption`. Composer's existing draft is untouched. After user sends from sheet, draft remains. |

## Testing

Automation-first. Goal: zero manual-test scripts the user has to run by
hand for known scenarios.

### Build verification

Run after every implementation step:

```bash
cd gitchat-ios-native
xcodegen generate
xcodebuild build -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' -quiet
```

### XCUITest target (new)

Add `GitchatIOSUITests` target in `project.yml`. Tests programmatically
populate `UIPasteboard.general` and drive the composer:

| ID | Scenario | Setup | Action | Assert |
|---|---|---|---|---|
| T1 | Image-only paste opens sheet | `UIPasteboard.general.image = testImage` | Tap composer, `typeKey("v", .command)` | `app.sheets.firstMatch.waitForExistence(timeout: 2)` is true; `app.images["paste-preview-image"].exists` |
| T2 | Text-only paste inserts text | `UIPasteboard.general.string = "hello"` | Same | composer value == "hello"; no sheet |
| T3 | Image+text paste = text only (Telegram) | `UIPasteboard.general.items = [["public.utf8-plain-text": "cap", "public.png": pngData]]` | Same | composer value == "cap"; no sheet |
| T4 | Empty clipboard no-ops | `UIPasteboard.general.items = []` | Same | composer value unchanged; no sheet |
| T5 | Regression: PhotosPicker still opens sheet | (no clipboard setup) | Tap paperclip → pick image | Sheet appears |
| T6 | Regression: drop callback still fires | Inject `NSItemProvider` with image into the drop modifier via test hook (full drag-drop gesture is not scriptable in XCUITest; use a programmatic seam in `CatalystDropModifier` exposed under `#if DEBUG`) | invoke seam | Sheet appears |
| T7 | Regression: composer multi-line (iOS only) | Type "a", press Shift+Return, type "b", repeat to 4 lines (avoid bare Return on Catalyst — that submits) | inspect | Field shows 4 lines; intrinsic height grows |
| T8 | Regression: Catalyst Return submits | Type "hi", press Return | inspect | Message sent, composer cleared |
| T9 | Regression: Catalyst Shift+Return = newline | Type "hi", press Shift+Return | inspect | Composer contains "hi\n" |

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSUITests
```

For Catalyst:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:GitchatIOSUITests
```

### Accessibility identifiers required

To enable XCUITest assertions, add `.accessibilityIdentifier(…)` on:

- Composer text view: `"composer"`
- Image preview in `ImageSendPreview`: `"paste-preview-image"`
- Sheet send button: `"sheet-send"` (regression tests rely on this)

These IDs are stable contracts; document them in the implementation
plan.

### What still needs human verification

Only scenarios that genuinely cannot be scripted:

1. iOS "Pasted from <app>" privacy banner. The banner is rendered by
   SpringBoard, not the app, and XCUITest cannot reach it. Spot-check
   on a real device once during PR review.
2. macOS Cmd+Ctrl+Shift+4 → real screenshot writes a `public.tiff` +
   `public.png` payload to NSPasteboard. The XCUITest scenarios cover
   the equivalent app-level behavior by setting `UIPasteboard.image`
   programmatically. One real-device confirmation that
   `UIPasteboard.general.image` resolves correctly from a Catalyst
   Cmd+V on a true OS screenshot — not the simulated image data —
   is the one manual check that survives.

Everything else is automated.

## Rollout

1. Generate test image asset; add `GitchatIOSUITests` target to
   `project.yml`; `xcodegen generate`.
2. Add `accessibilityIdentifier` to existing composer / sheet elements.
3. Implement `PasteableUITextView`.
4. Implement `PasteableTextField` (UIViewRepresentable).
5. Migrate `ChatInputView.textField` to use `PasteableTextField` on both
   platforms. Verify multi-line + send-on-Return regressions in
   simulator before continuing.
6. Wire `onPasteImage` callback through `ChatInputView` →
   `ChatView` / `ChatDetailView` into `pendingDropImages` /
   `showDropConfirm`.
7. Delete `ClipboardWatcher.swift`, `ChatClipboardChip.swift`, and all
   references. Verify with `grep -rn`.
8. Add XCUITest cases T1–T9.
9. `xcodebuild test` on iOS Simulator and Mac Catalyst destinations.
10. PR against `main` (per repo workflow). Title:
    `feat(ios): paste image from clipboard into chat composer`.

## Implementation risks

- **Catalyst focus ring suppression** for UITextView (see Component 2).
  Mitigation noted; verify on first build.
- **Drop test (T6)** cannot be driven by a real drag gesture in
  XCUITest. Plan: expose a `#if DEBUG` seam on `CatalystDropModifier`
  that calls the same `onDrop` closure with a synthesised
  `NSItemProvider`. If this is unacceptable, drop test stays manual.
- **Catalyst paste of true OS screenshot** (Cmd+Ctrl+Shift+4) traverses
  the NSPasteboard → UIPasteboard bridge. `UIPasteboard.image` is
  expected to resolve, but the bridge has had quirks in past iOS
  releases. One real-device verification on first build is the only
  manual scenario.

## Open questions

None pending — all design decisions confirmed during brainstorming.

## References

- `GitchatIOS/Features/Conversations/ChatDetail/Input/ChatInputView.swift`
  — current composer
- `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift:449`
  — `uploadImagesAndSend`, the shared upload entry point
- `GitchatIOS/Features/Conversations/ChatDetailView.swift:601`
  — `sendDroppedImages`, the existing send pipeline that paste reuses
- `GitchatIOS/Features/Conversations/ChatDetail/ImageSendPreview.swift`
  — preview/caption sheet, reused for paste
- `GitchatIOS/Features/Conversations/ChatDetail/CatalystDropModifier.swift`
  — drop flow, paste mirrors this entry point

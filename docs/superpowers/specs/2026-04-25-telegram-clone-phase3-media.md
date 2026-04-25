# Phase 3: Media — Telegram Clone Spec

## Mục tiêu
Video playback, file sharing, document picker — tất cả client-side, không cần BE change. BE đã support upload mọi file type qua cùng endpoint.

## Scope: Chỉ những gì BE đã support. BE gaps logged ở cuối.

---

## Features

### 1. Video Send từ Picker

**Hiện trạng:** Video chỉ gửi được qua share extension. PhotosPicker trong chat chỉ chọn ảnh.

**Thay đổi:**
- Thêm `.videos` vào `PHPickerFilter` (hiện chỉ `.images`)
- Max selection: 10 items (giữ nguyên)
- Upload qua cùng `POST /messages/upload` endpoint
- Attachment type: `"video"` (thay vì hardcode `"image"`)

**Compression:**
- `AVAssetExportSession` preset `.mediumQuality` trước upload
- Hiện estimated size trên preview screen
- Cancel button cho compression

**Edge cases (P0):**
- Video quá lớn (>100MB) → cảnh báo user, suggest trim
- Compression fail → fallback upload raw, warn user về size
- Network mất giữa upload → retry logic (đã có cho images)

---

### 2. Video Playback Inline

**Hiện trạng:** Video hiện như generic file attachment (📎 icon + filename). Không play được.

**Thay đổi:**
- Thumbnail: auto-generate bằng `AVAssetImageGenerator` từ attachment URL
- Play button: 48px circle, center, `rgba(0,0,0,0.5)` + backdrop blur
- Tap play → inline AVPlayer (muted, loop)
- Tap fullscreen → `AVPlayerViewController` (controls, sound, landscape)
- Settings toggle: "Autoplay videos" (đã có toggle, chưa implement)

**Bubble shape:**
- Video bubble: rounded corners match bubble direction (18px, tail corner 4px)
- Không có text padding — video edge-to-edge trong bubble
- Max width: 280px, height: aspect ratio preserved (max 300px)

**Edge cases (P0):**
- Video URL 404 → placeholder "Video không khả dụng"
- Slow network → loading spinner overlay trên thumbnail
- Nhiều video trong viewport → chỉ autoplay video gần nhất center

---

### 3. Video Thumbnail + Duration

**Thumbnail:**
- Client generate bằng `AVAssetImageGenerator.generateCGImageAsynchronously(for: CMTime(value: 1, timescale: 1))`
- Cache thumbnail vào `ImageCache` (key: video URL + "thumb")
- Fallback: gradient placeholder nếu generate fail

**Duration badge:**
- Position: bottom-left, overlay trên thumbnail
- Style: `rgba(0,0,0,0.5)`, border-radius 8px, padding 2px 6px
- Font: 11px bold, white
- Format: `"M:SS"` (e.g., "1:23"), `"H:MM:SS"` nếu >= 1h
- Đọc từ `AVAsset.duration` (client-side, không cần BE)

**Timestamp:**
- Position: bottom-right (giống image)
- Outgoing: + checkmarks

---

### 4. File Send từ Document Picker

**Hiện trạng:** Không có document picker trong chat. File chỉ gửi qua share extension.

**Thay đổi:**
- Thêm nút document picker cạnh send button trong composer
- Icon: file document (#D16238)
- `UIDocumentPickerViewController(forOpeningContentTypes: [.item])` — mọi file type
- Upload qua cùng `POST /messages/upload` endpoint
- Attachment type: detect từ `UTType` → "file", "video", "image"

**Flow:**
1. Tap document icon → UIDocumentPicker opens
2. User chọn file → show preview (filename + size)
3. Tap send → upload + send message

---

### 5. File Preview Card

**Hiện trạng:** File attachment hiện như plain link text hoặc generic 📎 icon.

**Thay đổi — File card trong bubble:**

| Element | Incoming | Outgoing |
|---------|----------|----------|
| Background | White bubble | Accent bubble |
| File icon | 42x50px, color theo type | 42x50px, white outline |
| Filename | 14px semibold, #333 | 14px semibold, #fff |
| Size + type | 11px, #8E8E93 | 11px, rgba(255,255,255,0.6) |
| Timestamp | Inline, bottom | Inline + checkmarks |

**File type icon colors:**
| Type | Color | Label |
|------|-------|-------|
| PDF | #FF3B30 | PDF |
| DOC/DOCX | #007AFF | DOC |
| XLS/XLSX | #34C759 | XLS |
| ZIP/RAR | #AF52DE | ZIP |
| PPT/PPTX | #FF9500 | PPT |
| TXT/CSV | #8E8E93 | TXT |
| Other | #C7C7CC | FILE |

**Detect type:** Từ `mime_type` hoặc file extension trong `filename`.

---

### 6. File Download / Save to Files

**Tap file card:**
1. Download file (URLSession, background)
2. Progress bar overlay trên file card (accent color)
3. Complete → `UIDocumentInteractionController` hoặc `UIActivityViewController`
4. Options: "Save to Files", "Share", "Open in..."
5. Toast "Đã lưu" sau save

**Edge cases (P0):**
- Download fail → retry button trên card
- File đã download → open directly (cache check)
- Large file (>50MB) → confirm dialog trước download

---

### 7. Image Grid → Telegram Style

**Hiện trạng:** iMessage-style grid (ChatAttachmentsGrid.swift) — rounded corners generic, không match bubble shape.

**Thay đổi:**
- Border-radius: match bubble direction (18px outer, tail corner 4px)
- Gap: 2px (giữ nguyên)
- Timestamp overlay: bottom-right trên ảnh cuối cùng trong grid
- Checkmarks: outgoing images có checkmarks overlay
- Shadow: remove bubble shadow cho media-only messages

**Layout giữ nguyên:** 1 ảnh full-width, 2 ảnh 50/50, 3 ảnh 62/38, 4+ grid 2x2 + "+N".

---

### 8. Video Compression

**Pre-upload compression:**
- `AVAssetExportSession(asset:, presetName: AVAssetExportPresetMediumQuality)`
- Output: `.mp4` (H.264)
- Hiện estimated size trên send preview
- Progress bar trong preview screen
- Cancel button abort compression + upload

---

## Composer Changes

**Hiện tại:** `[📎 clip]` `[input field]` `[send button]`

**Sau Phase 3:** `[📎 clip]` `[input field]` `[📄 doc picker]` `[send button]`

- Clip button: mở PhotosPicker (images + videos)
- Doc picker button: mở UIDocumentPicker (files)
- Doc picker icon: file outline, accent color, 28px circle light accent background

---

## Files cần sửa

| File | Thay đổi |
|------|----------|
| `ChatInputView.swift` | Thêm document picker button, PhotosPicker filter += .videos |
| `ChatViewModel.swift` | Video upload flow, file upload flow, type detection |
| `ChatAttachmentsGrid.swift` | Telegram-style rounded corners, timestamp overlay |
| `ChatMessageView.swift` | Video bubble + file card rendering |
| **Mới:** `VideoBubble.swift` | Inline AVPlayer, thumbnail, play button, duration |
| **Mới:** `FileCardView.swift` | File preview card (icon + name + size) |
| **Mới:** `VideoCompressor.swift` | AVAssetExportSession wrapper |
| **Mới:** `FileDownloader.swift` | Download + save to Files |
| `ImageSendPreview.swift` | Extend cho video preview (duration, compress progress) |
| `CachedAsyncImage.swift` | Cache video thumbnails |

## BE Dependencies — Logged cho tương lai

| Item | Priority | Chi tiết |
|------|----------|----------|
| **Media gallery endpoint** | BLOCKED (Phase 4) | `GET /conversations/:id/media?type=image\|video\|file` — paginated. Cần cho shared media tab. |
| **Video metadata** | NICE | Thêm `duration` (Float), `thumbnail_url` (String) vào MessageAttachment response. Client đang tự generate nhưng BE trả sẵn nhanh hơn + consistent cross-device. |
| **Video transcode** | NICE | Server-side convert + adaptive bitrate streaming. Giảm bandwidth cho mobile. |
| **Attachment type enforcement** | NICE | BE auto-detect và set `type` field (image/video/file/audio) từ mime_type, thay vì rely on client gửi lên. |

## Estimate

~40-56h total (1-1.5 sprints). Chia 2 đợt:
- **S (0.5-1 sprint):** Video thumbnail + playback + file card + download + Telegram image grid
- **M (0.5 sprint):** Video send + compression + document picker + polish

## Decisions đã chốt

- Video playback: inline AVPlayer (muted) + tap fullscreen AVPlayerViewController
- Video thumbnail: client-side AVAssetImageGenerator (không cần BE thumbnail_url)
- Video duration: client-side AVAsset.duration (không cần BE duration field)
- File card: color-coded icon theo file type, trong bubble
- Document picker: nút riêng cạnh send button (không gộp vào clip menu)
- Compression: AVAssetExportSession medium quality, có cancel
- Scope: chỉ client-side, BE gaps logged cho Phase 4+

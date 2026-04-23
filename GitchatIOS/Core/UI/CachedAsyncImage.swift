import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// A tiny in-memory image cache shared across the app. `AsyncImage`
/// re-fetches every time it appears, which causes visible flicker and
/// occasional permanent failures when a lazy stack recycles a row.
/// This cache holds the decoded `UIImage` keyed by URL so the second
/// appearance is instant and resilient to lazy-stack churn.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    // Strong-reference dictionary so images survive scrolling without
    // being evicted under memory pressure. Only cleared on explicit
    // memory warning. nonisolated(unsafe) so we can read/write from any
    // thread guarded by the lock.
    private nonisolated(unsafe) var storage: [String: UIImage] = [:]
    private let storageLock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private nonisolated static let diskQueue = DispatchQueue(
        label: "chat.git.ImageCache.disk", qos: .utility, attributes: .concurrent
    )

    private nonisolated static func key(_ url: URL, _ maxPixelSize: CGFloat?) -> String {
        if let s = maxPixelSize { return "\(url.absoluteString)|\(Int(s))" }
        return url.absoluteString
    }

    private nonisolated static var diskDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func diskFile(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let name = hash.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent("\(name).jpg")
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.purge()
        }
    }

    nonisolated func image(for url: URL, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let key = Self.key(url, maxPixelSize)
        storageLock.lock()
        if let mem = storage[key] { storageLock.unlock(); return mem }
        storageLock.unlock()
        // Disk fallback — small file, sync read is fast (~ms).
        let file = Self.diskFile(key)
        guard let data = try? Data(contentsOf: file),
              let img = UIImage(data: data)
        else { return nil }
        storageLock.lock(); storage[key] = img; storageLock.unlock()
        return img
    }

    nonisolated func store(_ image: UIImage, for url: URL, maxPixelSize: CGFloat? = nil) {
        let key = Self.key(url, maxPixelSize)
        storageLock.lock(); storage[key] = image; storageLock.unlock()
        // Persist to disk in the background.
        let file = Self.diskFile(key)
        Self.diskQueue.async {
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    func purge() {
        storageLock.lock(); defer { storageLock.unlock() }
        storage.removeAll(keepingCapacity: false)
    }

    /// Fire-and-forget cache warming for URLs about to scroll into
    /// view. Routes through the inflight map so duplicate requests
    /// share one download. Safe to call with empty / file:// URLs.
    nonisolated func prefetch(urls: [URL], maxPixelSize: CGFloat? = nil) {
        for url in urls {
            guard !url.isFileURL else { continue }
            if image(for: url, maxPixelSize: maxPixelSize) != nil { continue }
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.load(url, maxPixelSize: maxPixelSize)
            }
        }
    }

    /// Cancel any in-flight fetches for the given URLs. No-op for URLs
    /// that have no task in flight. Hops to the MainActor because
    /// `inflight` is actor-isolated.
    nonisolated func cancelPrefetch(urls: [URL], maxPixelSize: CGFloat? = nil) {
        let keys = urls.map { Self.key($0, maxPixelSize) }
        Task { @MainActor in
            for key in keys {
                if let task = self.inflight.removeValue(forKey: key) {
                    task.cancel()
                }
            }
        }
    }

    func load(_ url: URL, maxPixelSize: CGFloat? = nil) async -> UIImage? {
        if let cached = image(for: url, maxPixelSize: maxPixelSize) { return cached }
        let cacheKey = Self.key(url, maxPixelSize)
        if let task = inflight[cacheKey] { return await task.value }

        let task = Task<UIImage?, Never> { [weak self] in
            defer { self?.inflight[cacheKey] = nil }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }
            let processed: UIImage?
            if let maxPixelSize {
                // Use ImageIO to downsample directly from the source data
                // without ever decoding the full-resolution image. Massive
                // memory + CPU win for large camera shots displayed in
                // small chat bubbles.
                processed = Self.downsample(data: data, maxPixelSize: maxPixelSize)
            } else if let raw = UIImage(data: data) {
                processed = Self.decode(raw) ?? raw
            } else {
                processed = nil
            }
            if let processed {
                self?.store(processed, for: url, maxPixelSize: maxPixelSize)
            }
            return processed
        }
        inflight[cacheKey] = task
        return await task.value
    }

    private static func decode(_ image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else {
            return nil
        }
        let scale = UIScreen.main.scale
        let pixelSize = maxPixelSize * scale
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

/// Drop-in replacement for `AsyncImage` that uses `ImageCache` to avoid
/// re-downloading on lazy-stack recycling. Supports local `file://`
/// URLs synchronously via `UIImage(contentsOfFile:)`.
///
/// When `fixedHeight` is set, the image is locked to that height and
/// the width varies to preserve the intrinsic aspect ratio. This
/// prevents chat layout reflow when async images finish loading — only
/// the bubble width changes, the vertical position of everything else
/// stays put.
struct CachedAsyncImage: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholderStyle: PlaceholderStyle
    let fixedHeight: CGFloat?
    /// When set, the loaded image is rendered in a `.frame(width:, height:)`
    /// computed from its intrinsic aspect ratio so the view never has
    /// blank gutters around a portrait photo.
    let fitMaxWidth: CGFloat?
    let fitMaxHeight: CGFloat?
    let maxPixelSize: CGFloat?

    enum PlaceholderStyle {
        /// Filled rectangle placeholder — good for chat bubbles where
        /// the bubble needs a visible loading surface.
        case filled
        /// Transparent background with only a spinner — good for the
        /// full-screen image viewer over a black backdrop.
        case transparent
    }

    @State private var image: UIImage?

    init(
        url: URL?,
        contentMode: ContentMode = .fit,
        placeholder: PlaceholderStyle = .filled,
        fixedHeight: CGFloat? = nil,
        fitMaxWidth: CGFloat? = nil,
        fitMaxHeight: CGFloat? = nil,
        maxPixelSize: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholderStyle = placeholder
        self.fixedHeight = fixedHeight
        self.fitMaxWidth = fitMaxWidth
        self.fitMaxHeight = fitMaxHeight
        // Default thumbnail ceiling in points — multiplied by screen
        // scale inside ImageCache.downsample so the result has enough
        // pixels for a sharp retina render. Bumped from 320 because a
        // 220pt-tall portrait needs ~660 physical pixels at @3x.
        self.maxPixelSize = maxPixelSize ?? (fixedHeight.map { max(320, $0) } ?? 800)
        if let url {
            if url.isFileURL {
                _image = State(initialValue: UIImage(contentsOfFile: url.path))
            } else {
                _image = State(initialValue: ImageCache.shared.image(for: url, maxPixelSize: self.maxPixelSize))
            }
        }
    }

    var body: some View {
        Group {
            if let image {
                if let h = fixedHeight {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: h)
                } else if let maxW = fitMaxWidth, let maxH = fitMaxHeight {
                    // Compute an exact fit size from the loaded image's
                    // intrinsic aspect, then pin the view to those
                    // dimensions. `.frame(width:height:)` is concrete
                    // so the view cannot pick up blank gutters from
                    // the parent's offered bounds.
                    let aspect = max(0.0001, image.size.width / max(image.size.height, 1))
                    let fitted: CGSize = {
                        if aspect >= 1 {
                            let fw = min(maxW, image.size.width)
                            return CGSize(width: fw, height: fw / aspect)
                        } else {
                            let fh = min(maxH, image.size.height)
                            return CGSize(width: fh * aspect, height: fh)
                        }
                    }()
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderStyle {
        case .filled:
            if let h = fixedHeight {
                Color(.secondarySystemBackground)
                    .frame(width: h, height: h)
                    .overlay(ProgressView().tint(.secondary))
            } else if let maxW = fitMaxWidth, let maxH = fitMaxHeight {
                let side = min(maxW, maxH)
                Color(.secondarySystemBackground)
                    .frame(width: side, height: side)
                    .overlay(ProgressView().tint(.secondary))
            } else {
                Color(.secondarySystemBackground)
                    .frame(width: 200, height: 200)
                    .overlay(ProgressView().tint(.secondary))
            }
        case .transparent:
            Color.clear
                .overlay(ProgressView().tint(.white))
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
            return
        }
        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }
        let loaded = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize)
        image = loaded
    }
}

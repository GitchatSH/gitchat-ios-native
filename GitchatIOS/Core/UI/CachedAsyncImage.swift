import SwiftUI
import UIKit

/// A tiny in-memory image cache shared across the app. `AsyncImage`
/// re-fetches every time it appears, which causes visible flicker and
/// occasional permanent failures when a lazy stack recycles a row.
/// This cache holds the decoded `UIImage` keyed by URL so the second
/// appearance is instant and resilient to lazy-stack churn.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }

    nonisolated func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func load(_ url: URL) async -> UIImage? {
        if let cached = image(for: url) { return cached }
        if let task = inflight[url] { return await task.value }

        let task = Task<UIImage?, Never> { [weak self] in
            defer { self?.inflight[url] = nil }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return nil }
            self?.store(image, for: url)
            return image
        }
        inflight[url] = task
        return await task.value
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
        fixedHeight: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholderStyle = placeholder
        self.fixedHeight = fixedHeight
        // Prime the state synchronously from the in-memory cache so
        // rows recycled by LazyVStack don't flash a placeholder on
        // reappearance — the image is already there on first render.
        if let url {
            if url.isFileURL {
                _image = State(initialValue: UIImage(contentsOfFile: url.path))
            } else {
                _image = State(initialValue: ImageCache.shared.image(for: url))
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
            } else {
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
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
        if let cached = await ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        let loaded = await ImageCache.shared.load(url)
        image = loaded
    }
}

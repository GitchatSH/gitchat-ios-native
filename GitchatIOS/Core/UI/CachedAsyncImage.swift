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

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
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
struct CachedAsyncImage: View {
    let url: URL?
    let contentMode: ContentMode

    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fit) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemBackground)
                    .overlay(ProgressView().tint(.secondary))
            }
        }
        .task(id: url) { await load() }
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

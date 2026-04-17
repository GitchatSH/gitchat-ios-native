import SwiftUI
import UIKit

final class OGFetcher: @unchecked Sendable {
    static let shared = OGFetcher()
    private var cache: [String: OGData] = [:]
    private let lock = NSLock()

    struct OGData: Sendable {
        let title: String?
        let description: String?
        let imageURL: String?
        let host: String?
    }

    func cached(_ url: URL) -> OGData? {
        lock.lock(); defer { lock.unlock() }
        return cache[url.absoluteString]
    }

    private static func youtubeVideoId(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube.com"), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        return nil
    }

    func fetch(_ url: URL, completion: @escaping (OGData) -> Void) {
        let key = url.absoluteString
        lock.lock()
        if let c = cache[key] { lock.unlock(); completion(c); return }
        lock.unlock()

        if let vid = Self.youtubeVideoId(url) {
            let thumb = "https://img.youtube.com/vi/\(vid)/hqdefault.jpg"
            let noembed = URL(string: "https://noembed.com/embed?url=https://www.youtube.com/watch?v=\(vid)")!
            URLSession.shared.dataTask(with: noembed) { [weak self] data, _, _ in
                var title: String?
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    title = json["title"] as? String
                }
                let result = OGData(title: title ?? "YouTube", description: nil, imageURL: thumb, host: "youtube.com")
                self?.store(key, result)
                completion(result)
            }.resume()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data.prefix(50_000), encoding: .utf8)
                    ?? String(data: data.prefix(50_000), encoding: .ascii)
            else {
                let empty = OGData(title: nil, description: nil, imageURL: nil, host: url.host)
                self?.store(key, empty)
                completion(empty)
                return
            }

            let title = Self.og("og:title", html) ?? Self.htmlTitle(html)
            let desc = Self.og("og:description", html)
            let img = Self.og("og:image", html)

            var imageURL: String?
            if let img, !img.isEmpty {
                if img.hasPrefix("http") { imageURL = img }
                else if img.hasPrefix("//") { imageURL = "https:\(img)" }
            }

            let result = OGData(title: title, description: desc, imageURL: imageURL, host: url.host)
            self?.store(key, result)
            completion(result)
        }.resume()
    }

    private func store(_ key: String, _ data: OGData) {
        lock.lock(); cache[key] = data; lock.unlock()
    }

    private static func og(_ prop: String, _ html: String) -> String? {
        let patterns = [
            "property=\"\(prop)\"[^>]*content=\"([^\"]+)\"",
            "content=\"([^\"]+)\"[^>]*property=\"\(prop)\""
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let val = String(html[range])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            return val.isEmpty ? nil : val
        }
        return nil
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let val = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return val.isEmpty ? nil : val
    }
}

struct LinkPreviewCard: View {
    let url: URL
    let isMe: Bool
    @State private var og: OGFetcher.OGData?

    init(url: URL, isMe: Bool) {
        self.url = url
        self.isMe = isMe
        _og = State(initialValue: OGFetcher.shared.cached(url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let og, og.title != nil || og.imageURL != nil {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let imgStr = og.imageURL, let imgURL = URL(string: imgStr) {
                            CachedAsyncImage(url: imgURL, contentMode: .fill, maxPixelSize: 600)
                                .frame(height: 130)
                                .frame(maxWidth: .infinity)
                                .clipped()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if let title = og.title, !title.isEmpty {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(isMe ? .white : Color(.label))
                            }
                            if let desc = og.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(isMe ? Color.white.opacity(0.8) : .secondary)
                            }
                            Text(url.host ?? "")
                                .font(.caption2)
                                .foregroundStyle(isMe ? Color.white.opacity(0.6) : Color(.tertiaryLabel))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    #if targetEnvironment(macCatalyst)
                    .frame(width: 300)
                    #else
                    .frame(maxWidth: .infinity)
                    #endif
                    .background(isMe ? Color.white.opacity(0.12) : Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .instantTooltip(url.absoluteString)
            }
        }
        .onAppear {
            guard og == nil else { return }
            if let c = OGFetcher.shared.cached(url) {
                og = c; return
            }
            OGFetcher.shared.fetch(url) { data in
                DispatchQueue.main.async {
                    og = data
                }
            }
        }
    }
}

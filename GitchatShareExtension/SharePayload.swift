import Foundation
import UIKit
import UniformTypeIdentifiers

struct SharePayload {
    var text: String?
    var url: URL?
    var images: [UIImage] = []
    var files: [(data: Data, filename: String, mime: String)] = []

    var isEmpty: Bool {
        (text ?? "").isEmpty && url == nil && images.isEmpty && files.isEmpty
    }

    var composedText: String {
        var parts: [String] = []
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let u = url { parts.append(u.absoluteString) }
        return parts.joined(separator: "\n")
    }
}

enum SharePayloadLoader {
    /// Walks the share extension's inputItems pulling out text, URLs,
    /// and any images or generic files that were handed over.
    static func load(from context: NSExtensionContext) async -> SharePayload {
        var payload = SharePayload()
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        for item in items {
            if let contentText = item.attributedContentText?.string,
               !contentText.isEmpty,
               payload.text == nil {
                payload.text = contentText
            }
            for provider in item.attachments ?? [] {
                await ingest(provider, into: &payload)
            }
        }
        return payload
    }

    private static func ingest(_ provider: NSItemProvider, into payload: inout SharePayload) async {
        // Images are checked before URLs — Photos shares images with a
        // `public.url` type attached too (the on-disk location), and we
        // want the image data, not the URL string.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let img = await loadImage(provider) {
                payload.images.append(img)
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            if let file = await loadFile(provider, typeId: UTType.movie.identifier, defaultMime: "video/mp4") {
                payload.files.append(file)
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let obj = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil),
               let url = obj as? URL, !url.isFileURL {
                payload.url = url
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let obj = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil),
               let text = obj as? String, payload.text == nil {
                payload.text = text
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let file = await loadFile(provider, typeId: UTType.fileURL.identifier, defaultMime: "application/octet-stream") {
                payload.files.append(file)
            }
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        if let obj = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) {
            if let img = obj as? UIImage { return img }
            if let url = obj as? URL, let img = UIImage(contentsOfFile: url.path) { return img }
            if let data = obj as? Data, let img = UIImage(data: data) { return img }
        }
        return nil
    }

    private static func loadFile(_ provider: NSItemProvider, typeId: String, defaultMime: String) async -> (Data, String, String)? {
        guard let obj = try? await provider.loadItem(forTypeIdentifier: typeId, options: nil) else { return nil }
        if let url = obj as? URL, let data = try? Data(contentsOf: url) {
            let mime = mimeType(for: url) ?? defaultMime
            return (data, url.lastPathComponent, mime)
        }
        if let data = obj as? Data {
            return (data, "file.bin", defaultMime)
        }
        return nil
    }

    private static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }
}

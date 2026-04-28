import SwiftUI
import Foundation

/// Pure text-processing helpers for chat message bodies. No view state
/// — bundled here so `ChatMessageView` stays focused on layout.
///
/// Handles three orthogonal transformations:
/// 1. "Forwarded from @login" header extraction (Gitchat-specific
///    prefix the forward sheet writes into the outgoing body).
/// 2. Link detection → underlined + bolded + tappable.
/// 3. `@login` mention detection → bolded + `gitchat://user/<login>`
///    link which the env `OpenURLAction` routes to the profile sheet.
///
/// Results are cached in an `NSCache` keyed by body + isMe so typing,
/// scrolling, and list-reconfigure paths don't re-parse on every body
/// rebuild.
enum ChatMessageText {

    // MARK: Forwarded header

    /// Returns `(sender, remainingBody)` when the body begins with our
    /// "Forwarded from @<login>\n" prefix, otherwise `(nil, body)`.
    static func parseForwarded(_ raw: String) -> (forwardedFrom: String?, body: String) {
        guard let regex = forwardedRegex,
              let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
              match.numberOfRanges >= 2,
              let nameRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range, in: raw)
        else {
            return (nil, raw)
        }
        let login = String(raw[nameRange])
        let body = String(raw[fullRange.upperBound...])
        return (login, body)
    }

    // MARK: Attributed body (links + mentions)

    static func attributed(_ raw: String, isMe: Bool) -> AttributedString {
        let key = "\(isMe ? 1 : 0)|\(raw)" as NSString
        if let cached = attributedCache.object(forKey: key) {
            return AttributedString(cached)
        }
        var attr = AttributedString(raw)
        // Links
        if let detector = linkDetector {
            let ns = raw as NSString
            let matches = detector.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard let url = m.url,
                      let r = Range(m.range, in: raw),
                      let aRange = attr.range(of: String(raw[r])) else { continue }
                attr[aRange].link = url
                attr[aRange].underlineStyle = .single
            }
        }
        // Mentions
        if let regex = mentionRegex {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard let r = Range(m.range, in: raw) else { continue }
                let token = String(raw[r])
                if let aRange = attr.range(of: token) {
                    let login = String(token.dropFirst())
                    attr[aRange].link = URL(string: "gitchat://user/\(login)")
                }
            }
        }
        attributedCache.setObject(NSAttributedString(attr), forKey: key)
        return attr
    }

    // MARK: Link preview

    static func firstURL(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }
        let ns = text as NSString
        let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        return match?.url
    }

    // MARK: Full timestamp (tooltip)

    static func fullTimestamp(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return fullDateFormatter.string(from: date)
    }

    // MARK: Privates

    private static let forwardedRegex: NSRegularExpression? = {
        // "Forwarded from @<login>\n" — capture login in group 1.
        try? NSRegularExpression(
            pattern: #"^Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\n"#,
            options: []
        )
    }()

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static let mentionRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "@[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", options: [])
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let attributedCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 500
        return c
    }()
}

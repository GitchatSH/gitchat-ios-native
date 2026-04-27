import UIKit

/// Manages floating avatar UIImageViews that stick to sender groups
/// during scroll in a 180°-rotated UITableView.
///
/// Avatars sit in a container view that's a sibling of the table
/// (not a subview), so they don't scroll with cell content.
final class AvatarOverlayManager {

    struct SenderGroup {
        let login: String
        let avatarURL: String?
        /// Visual top of the group (oldest message) in container coords.
        var topY: CGFloat
        /// Visual bottom of the group (newest message) in container coords.
        var bottomY: CGFloat
    }

    private let avatarSize: CGFloat = 32
    private var overlayViews: [String: UIImageView] = [:]
    private var imageCache: [String: UIImage] = [:]
    private(set) weak var container: UIView?

    func setContainer(_ view: UIView) {
        container = view
    }

    /// Update avatar positions based on current scroll state.
    /// Called from `scrollViewDidScroll` with pre-computed sender groups.
    func update(groups: [SenderGroup], composerInset: CGFloat) {
        guard let container = container else { return }

        let activeLogins = Set(groups.map(\.login))

        // Remove overlays for groups no longer visible
        for login in overlayViews.keys where !activeLogins.contains(login) {
            overlayViews[login]?.removeFromSuperview()
            overlayViews.removeValue(forKey: login)
        }

        let viewBottom = container.bounds.height - composerInset

        for group in groups {
            let iv = overlayView(for: group.login, avatarURL: group.avatarURL)

            // Sticky clamp: float at viewport bottom, pinned between group bounds
            let avatarY = min(
                max(group.topY, viewBottom - avatarSize),
                group.bottomY - avatarSize
            )

            iv.frame = CGRect(x: 16, y: avatarY, width: avatarSize, height: avatarSize)
            iv.isHidden = false
        }
    }

    func removeAll() {
        for (_, view) in overlayViews {
            view.removeFromSuperview()
        }
        overlayViews.removeAll()
    }

    // MARK: - Private

    private func overlayView(for login: String, avatarURL: String?) -> UIImageView {
        if let existing = overlayViews[login] {
            return existing
        }

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = avatarSize / 2
        iv.backgroundColor = .tertiarySystemFill
        iv.isAccessibilityElement = true
        iv.accessibilityLabel = "@\(login)"
        iv.accessibilityTraits = .button

        container?.addSubview(iv)
        overlayViews[login] = iv

        loadAvatar(for: login, url: avatarURL, into: iv)
        return iv
    }

    private func loadAvatar(for login: String, url: String?, into imageView: UIImageView) {
        let urlString = url ?? "https://github.com/\(login).png?size=64"
        guard let url = URL(string: urlString) else { return }

        if let cached = imageCache[login] {
            imageView.image = cached
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self, weak imageView] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.imageCache[login] = image
                imageView?.image = image
            }
        }.resume()
    }
}

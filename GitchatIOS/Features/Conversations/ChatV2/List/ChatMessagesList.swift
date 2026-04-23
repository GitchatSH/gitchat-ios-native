import SwiftUI
import UIKit

// MARK: - Synthetic row identifiers

/// Stable identifier for the typing-indicator row pinned to the end
/// of the list. Chosen so it never collides with a server-generated
/// message id.
let ChatV2TypingRowID: String = "__v2_typing__"

/// Stable identifier for the "seen" avatar row pinned under the last
/// outgoing message in a DM.
let ChatV2SeenRowID: String = "__v2_seen__"

// MARK: - Messages list

/// UITableView-backed chat list. Ports exyte/chat's `MessagesView`
/// architecture — UITableView + diffable data source + per-day
/// sections + `UIHostingConfiguration` cells — while staying a
/// `UIViewRepresentable` so the enclosing SwiftUI view can own all
/// state.
///
/// Why UITableView instead of UICollectionView compositional layout
/// (which the legacy `ChatCollectionView` used)?
/// - Native section-based day headers.
/// - Simpler row insertion semantics (automatic fade/top animations).
/// - Better-known cell recycling story for tall self-sizing content.
/// - UILongPressGestureRecognizer on the table reports the exact cell
///   frame with zero per-bubble overhead (the legacy approach used a
///   per-bubble SwiftUI GeometryReader.onChange that rebuilt the chat
///   body on every scroll tick — measurably janky on long lists).
struct ChatMessagesList<Cell: View>: UIViewRepresentable {

    // MARK: Inputs

    let items: [Message]
    let typingUsers: [String]
    let showSeen: Bool
    let seenAvatarURL: String?
    let pinnedIds: Set<String>
    let readCursors: [String: String]
    let pulsingId: String?
    let scrollToId: String?
    let isLoadingMore: Bool
    let bottomInset: CGFloat
    let scrollToBottomToken: Int
    @Binding var isAtBottom: Bool
    let onScrollToIdConsumed: () -> Void
    let onTopReached: () -> Void
    let onCellLongPressed: (Message, CGRect) -> Void
    let cellBuilder: (Message, Int) -> Cell

    // MARK: UIViewRepresentable plumbing

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITableView {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        tv.keyboardDismissMode = .interactive
        tv.showsVerticalScrollIndicator = false
        tv.allowsSelection = false
        tv.alwaysBounceVertical = true
        tv.contentInsetAdjustmentBehavior = .automatic
        tv.scrollsToTop = false
        // Self-sizing cells — UIHostingConfiguration reports its
        // intrinsic height.
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 80
        tv.sectionHeaderHeight = 0
        tv.estimatedSectionHeaderHeight = 0
        tv.sectionHeaderTopPadding = 0
        tv.sectionFooterHeight = UITableView.automaticDimension
        tv.estimatedSectionFooterHeight = 32

        // Rotation trick from exyte/chat (also how Telegram, Stream,
        // and iMessage handle it): flip the whole table 180° so data
        // is laid out oldest→newest from top→bottom, but visually
        // scrolls bottom→top. Inserting a "new row at the top" of
        // data therefore appears at the BOTTOM of the visible screen
        // — which is where newly-arrived messages belong. This
        // eliminates every rubber-band / tail-follow edge case because
        // the table's natural "keep content at top" behaviour IS the
        // chat's "stick to latest" behaviour.
        //
        // Each cell's SwiftUI content is rotated 180° back so it
        // renders upright. Same for section headers.
        tv.transform = CGAffineTransform(rotationAngle: .pi)

        // Long-press → menu overlay in SwiftUI.
        let lp = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        lp.minimumPressDuration = 0.28
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        tv.addGestureRecognizer(lp)

        tv.delegate = context.coordinator
        tv.prefetchDataSource = context.coordinator
        context.coordinator.attach(table: tv)
        context.coordinator.apply(items: items, typingUsers: typingUsers, showSeen: showSeen, animated: false)
        return tv
    }

    func updateUIView(_ tv: UITableView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        let prevIDs = coord.lastItems.map(\.id)
        let newIDs = items.map(\.id)

        // In-place edits (reactions, edit, unsend): reconfigure the
        // specific rows so the cell re-renders with fresh content.
        if !coord.lastItems.isEmpty {
            let prevById = Dictionary(uniqueKeysWithValues: coord.lastItems.map { ($0.id, $0) })
            let changedIDs = items.compactMap { m -> String? in
                if let prev = prevById[m.id], prev != m { return m.id }
                return nil
            }
            if !changedIDs.isEmpty {
                coord.lastItems = items
                coord.reconfigure(ids: changedIDs)
            }
        }

        // Detect prepend (older page) vs append (new message) in
        // data space — independent of rotation.
        let isPrepend =
            !prevIDs.isEmpty && !newIDs.isEmpty &&
            newIDs.count > prevIDs.count &&
            newIDs.suffix(prevIDs.count) == ArraySlice(prevIDs)
        let isAppend =
            !prevIDs.isEmpty && newIDs.count > prevIDs.count &&
            newIDs.prefix(prevIDs.count) == ArraySlice(prevIDs)
        _ = isPrepend

        // Rotation-aware: "near bottom" visually = contentOffset near 0.
        let prevHeight = tv.contentSize.height
        let prevOffset = tv.contentOffset.y
        let wasNearBottom = tv.bounds.height > 0 && prevOffset < 200

        // Apply the new snapshot. Animated for new-message arrivals +
        // typing toggles; static for bulk reloads (cache hydration,
        // pagination which has its own offset compensation).
        let typingToggled = coord.lastTypingUsers != typingUsers
        let animate = isAppend || typingToggled
        coord.apply(items: items, typingUsers: typingUsers, showSeen: showSeen, animated: animate)

        // Pinned changes: reconfigure so the pin badge flips without
        // a full snapshot apply.
        if coord.lastPinnedIds != pinnedIds {
            let diff = coord.lastPinnedIds.symmetricDifference(pinnedIds)
            coord.lastPinnedIds = pinnedIds
            coord.reconfigure(ids: Array(diff))
        }

        // Read cursors: touch every message row so the seen-by avatars
        // (rendered inside the cell) re-evaluate.
        if coord.lastReadCursors != readCursors {
            coord.lastReadCursors = readCursors
            coord.reconfigure(ids: items.map(\.id))
        }

        // Pulse highlight — reconfigure leaving + entering rows so the
        // scale animation actually runs on the bubble.
        if coord.lastPulsingId != pulsingId {
            var affected: [String] = []
            if let previous = coord.lastPulsingId { affected.append(previous) }
            if let next = pulsingId { affected.append(next) }
            coord.lastPulsingId = pulsingId
            coord.reconfigure(ids: affected)
        }

        // Keyboard-driven scroll-to-bottom: ChatView's default SwiftUI
        // keyboard avoidance already shrinks the list's frame when the
        // keyboard opens, so we do NOT add a bottom contentInset here
        // (doing so double-counts and leaves a tall empty band below
        // the last message).
        //
        // `keyboard.height` animates every frame during the
        // interpolatingSpring so `bottomInset` changes on every tick.
        // We only want to fire scroll-to-bottom on the hidden→shown
        // TRANSITION, not every frame of the animation — otherwise
        // the scheduled scrolls pile up and the list bounces like a
        // spring. `keyboardWasOpen` is the edge detector.
        let isOpen = bottomInset > 0.5
        if coord.keyboardWasOpen != isOpen {
            coord.keyboardWasOpen = isOpen
            if isOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak tv] in
                    guard let tv else { return }
                    coord.scrollToBottom(in: tv, animated: true)
                }
            }
        }
        coord.lastBottomInset = bottomInset

        // With the rotated-table layout, prepending older messages
        // (pagination) adds rows at the FAR END of the data
        // (visually the top). The table stays parked at its current
        // contentOffset automatically — no manual compensation
        // needed. Latest-message arrivals go to (section 0, row 0) in
        // the snapshot = visually at the bottom; UITableView keeps
        // contentOffset stable, so if the user is parked at 0 they
        // naturally stay on the new latest row.
        //
        // That leaves only the initial-scroll case: when the chat
        // first renders, make sure we land at (0, 0) in case the
        // automatic dimension estimate left us slightly offset.
        if !coord.didInitialScroll && !items.isEmpty {
            coord.didInitialScroll = true
            coord.initialScrollAt = Date()
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                tv.setContentOffset(.zero, animated: false)
            }
        }
        _ = (wasNearBottom, prevHeight, prevOffset, isPrepend)

        // Jump-to-id (reply pulse + message search).
        if let id = scrollToId {
            DispatchQueue.main.async {
                coord.scrollTo(id: id, in: tv, animated: true)
                onScrollToIdConsumed()
            }
        }

        // Imperative scroll-to-bottom token (send button, etc.).
        if coord.lastScrollToBottomToken != scrollToBottomToken {
            coord.lastScrollToBottomToken = scrollToBottomToken
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                coord.scrollToBottom(in: tv, animated: true)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSourcePrefetching {
        var parent: ChatMessagesList
        fileprivate weak var table: UITableView?

        private var dataSource: UITableViewDiffableDataSource<String, String>!

        var lastItems: [Message] = []
        var lastTypingUsers: [String] = []
        var lastShowSeen: Bool = false
        var lastPinnedIds: Set<String> = []
        var lastReadCursors: [String: String] = [:]
        var lastPulsingId: String?
        var lastBottomInset: CGFloat = 0
        var keyboardWasOpen: Bool = false
        var lastScrollToBottomToken: Int = 0
        var didInitialScroll = false
        var initialScrollAt: Date?
        private var loadingMore = false

        init(parent: ChatMessagesList) {
            self.parent = parent
        }

        // Private cell reuse identifier. All rows use a single
        // UIHostingConfiguration, so one class is enough. Instance-
        // level rather than static because Swift forbids static
        // stored properties inside a nested generic type.
        private let cellID = "ChatV2MessageCell"

        func attach(table: UITableView) {
            self.table = table
            table.register(UITableViewCell.self, forCellReuseIdentifier: cellID)

            dataSource = UITableViewDiffableDataSource<String, String>(tableView: table) { [weak self] tv, indexPath, id in
                let cell = tv.dequeueReusableCell(withIdentifier: self?.cellID ?? "ChatV2MessageCell", for: indexPath)
                guard let self else { return cell }
                self.configure(cell: cell, id: id, indexPath: indexPath)
                return cell
            }
            dataSource.defaultRowAnimation = .fade
        }

        private func configure(cell: UITableViewCell, id: String, indexPath: IndexPath) {
            cell.backgroundColor = .clear
            cell.selectionStyle = .none

            // Every cell's SwiftUI content is rotated 180° to
            // counter the table's own 180° transform — so text
            // reads upright while the table scrolls in the
            // chat-natural direction. See makeUIView.
            if id == ChatV2TypingRowID {
                let logins = lastTypingUsers
                cell.contentConfiguration = UIHostingConfiguration {
                    TypingIndicatorRow(logins: logins)
                        .rotationEffect(.degrees(180))
                }
                .margins(.horizontal, 12)
                .margins(.vertical, 2)
                return
            }
            if id == ChatV2SeenRowID {
                let avatarURL = parent.seenAvatarURL
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack {
                        Spacer()
                        AvatarView(url: avatarURL, size: 16)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1))
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 2)
                    .rotationEffect(.degrees(180))
                }
                .margins(.horizontal, 12)
                .margins(.vertical, 2)
                return
            }
            guard let msg = lastItems.first(where: { $0.id == id }) else { return }
            let idx = lastItems.firstIndex(where: { $0.id == id }) ?? indexPath.row
            cell.contentConfiguration = UIHostingConfiguration {
                parent.cellBuilder(msg, idx)
                    .rotationEffect(.degrees(180))
            }
            .margins(.horizontal, 12)
            .margins(.vertical, 2)
        }

        // MARK: Snapshot application

        func apply(
            items: [Message],
            typingUsers: [String],
            showSeen: Bool,
            animated: Bool
        ) {
            lastItems = items
            lastTypingUsers = typingUsers
            lastShowSeen = showSeen

            var snap = NSDiffableDataSourceSnapshot<String, String>()
            // Rotation-aware snapshot: newest section FIRST, and
            // within each section the newest row FIRST. Combined
            // with the 180° rotation on the table, this lays content
            // out so:
            //   - section 0, row 0  = latest message  = visually at
            //                         the bottom of the screen
            //   - last section, last row = oldest message = visually
            //                              at the top
            // Pagination listens for "approached last section, last
            // row" via willDisplay below.
            let groups = ChatV2Sectioning.groupByDay(items)
            // Trailing rows (typing indicator / seen avatar row) belong
            // in data-space AFTER the latest message, so in the
            // rotated table they appear BELOW the latest bubble. In
            // rotated-snapshot space they go to section 0 as rows
            // BEFORE the latest message — i.e. prepended.
            var trailingRowsForLatestSection: [String] = []
            if !typingUsers.isEmpty { trailingRowsForLatestSection.append(ChatV2TypingRowID) }
            if showSeen { trailingRowsForLatestSection.append(ChatV2SeenRowID) }

            for (offset, group) in groups.reversed().enumerated() {
                snap.appendSections([group.sectionID])
                // `offset == 0` means this is the latest day section
                // (rotated: visually bottom). Prepend the trailing
                // synthetic rows here so they sit UNDER the newest
                // bubble.
                var rows = Array(group.messageIDs.reversed())
                if offset == 0 {
                    rows = trailingRowsForLatestSection + rows
                }
                snap.appendItems(rows, toSection: group.sectionID)
            }
            dataSource.apply(snap, animatingDifferences: animated)
        }

        func reconfigure(ids: [String]) {
            guard !ids.isEmpty else { return }
            var snap = dataSource.snapshot()
            let present = ids.filter { snap.itemIdentifiers.contains($0) }
            guard !present.isEmpty else { return }
            snap.reconfigureItems(present)
            dataSource.apply(snap, animatingDifferences: false)
        }

        // MARK: Scrolling

        /// "Bottom" visually = section 0, row 0 in the rotated table.
        func scrollToBottom(in tv: UITableView, animated: Bool) {
            let snap = dataSource.snapshot()
            guard let firstSection = snap.sectionIdentifiers.first else { return }
            guard snap.numberOfItems(inSection: firstSection) > 0 else { return }
            let indexPath = IndexPath(row: 0, section: 0)
            // `.top` in rotated-table space maps to `.bottom` in
            // visual space.
            tv.scrollToRow(at: indexPath, at: .top, animated: animated)
        }

        func scrollTo(id: String, in tv: UITableView, animated: Bool) {
            guard let indexPath = dataSource.indexPath(for: id) else { return }
            tv.scrollToRow(at: indexPath, at: .middle, animated: animated)
        }

        // MARK: UITableViewDelegate

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // With the rotation trick, the LAST row of the LAST
            // section is the oldest message visually (top of screen).
            // Trigger pagination there.
            let snap = dataSource.snapshot()
            let lastSection = snap.sectionIdentifiers.count - 1
            guard lastSection >= 0 else { return }
            let lastSectionID = snap.sectionIdentifiers[lastSection]
            let lastRow = snap.numberOfItems(inSection: lastSectionID) - 1
            if indexPath.section == lastSection,
               indexPath.row >= lastRow - 1,
               !loadingMore {
                fireLoadMore()
            }
        }

        func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
            // Date pill as section FOOTER, not header. In the rotated
            // table, footers render at the BOTTOM of a section in
            // rotation space = TOP of the section visually. That's
            // where the date separator belongs ("Today" above today's
            // first message, not below the last).
            let snap = dataSource.snapshot()
            guard section < snap.sectionIdentifiers.count else { return nil }
            let sectionID = snap.sectionIdentifiers[section]
            let label = ChatV2Sectioning.label(for: sectionID)
            let footer = UITableViewHeaderFooterView(reuseIdentifier: nil)
            footer.backgroundConfiguration = .clear()
            footer.contentConfiguration = UIHostingConfiguration {
                HStack {
                    Spacer()
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.vertical, 6)
                .rotationEffect(.degrees(180))
            }
            .margins(.all, 0)
            return footer
        }

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }

        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            UITableView.automaticDimension
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Rotation-aware "at bottom" detection — visually at the
            // bottom means content-offset near 0 (section 0 row 0 is
            // just above the viewport's top edge, which is the
            // screen's bottom after rotation).
            let atBottom = scrollView.contentOffset.y < 80
            if parent.isAtBottom != atBottom {
                let v = atBottom
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isAtBottom = v
                }
            }

            // Pagination: approaching the far end of the content (=
            // visually the TOP of the screen, = oldest messages).
            guard !loadingMore else { return }
            let distanceToEnd = scrollView.contentSize.height
                - (scrollView.contentOffset.y + scrollView.bounds.height)
            if distanceToEnd < 600 { fireLoadMore() }
        }

        private func fireLoadMore() {
            loadingMore = true
            parent.onTopReached()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.loadingMore = false
            }
        }

        // MARK: Long-press → menu

        @objc fileprivate func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let tv = table else { return }
            let point = gr.location(in: tv)
            guard let indexPath = tv.indexPathForRow(at: point) else { return }
            guard let cell = tv.cellForRow(at: indexPath) else { return }
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
            if id == ChatV2TypingRowID || id == ChatV2SeenRowID { return }
            guard let msg = lastItems.first(where: { $0.id == id }) else { return }
            Haptics.impact(.medium)
            let frame = cell.convert(cell.bounds, to: nil)
            parent.onCellLongPressed(msg, frame)
        }

        // MARK: Prefetch

        private func imageURLs(at indexPaths: [IndexPath]) -> [URL] {
            var urls: [URL] = []
            for ip in indexPaths {
                guard let id = dataSource.itemIdentifier(for: ip) else { continue }
                if id == ChatV2TypingRowID || id == ChatV2SeenRowID { continue }
                guard let msg = lastItems.first(where: { $0.id == id }) else { continue }
                if let atts = msg.attachments {
                    for a in atts where (a.type == "image") || (a.mime_type?.hasPrefix("image/") == true) {
                        if let u = URL(string: a.url), !u.isFileURL { urls.append(u) }
                    }
                }
                if let s = msg.attachment_url, let u = URL(string: s), !u.isFileURL {
                    urls.append(u)
                }
                if let s = msg.sender_avatar, let u = URL(string: s), !u.isFileURL {
                    urls.append(u)
                }
            }
            return urls
        }

        func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
            let urls = imageURLs(at: indexPaths)
            guard !urls.isEmpty else { return }
            ImageCache.shared.prefetch(urls: urls, maxPixelSize: 800)
        }

        func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
            let urls = imageURLs(at: indexPaths)
            guard !urls.isEmpty else { return }
            ImageCache.shared.cancelPrefetch(urls: urls, maxPixelSize: 800)
        }
    }
}

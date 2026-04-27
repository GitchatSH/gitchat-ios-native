import SwiftUI
import UIKit

// MARK: - Scroll proxy

/// Lets SwiftUI views call scroll commands directly on the
/// UITableView without going through the updateUIView cycle.
final class ChatScrollProxy: ObservableObject {
    weak var tableView: UITableView?

    func scrollToBottom(animated: Bool = true) {
        guard let tv = tableView else { return }
        let target = CGPoint(x: 0, y: -tv.contentInset.top)
        tv.setContentOffset(target, animated: animated)
    }
}

// MARK: - Synthetic row identifiers

/// Stable identifier for the typing-indicator row pinned to the end
/// of the list. Chosen so it never collides with a server-generated
/// message id.
let ChatTypingRowID: String = "__v2_typing__"

/// Stable identifier for the "seen" avatar row pinned under the last
/// outgoing message in a DM.
let ChatSeenRowID: String = "__v2_seen__"

/// Stable identifier for the "N unread messages" divider row.
let ChatUnreadDividerID: String = "__v2_unread__"

/// Prefix for synthetic date-pill rows. Using a regular row instead
/// of a section footer avoids UITableView `.plain` style's
/// sticky-footer behaviour, which pinned "Today" mid-screen as the
/// user scrolled past the day's last message.
private let ChatDateRowPrefix = "__v2_date__|"

private func chatDateRowID(for sectionID: String) -> String {
    "\(ChatDateRowPrefix)\(sectionID)"
}

private func chatIsDateRow(_ id: String) -> Bool {
    id.hasPrefix(ChatDateRowPrefix)
}

private func chatSectionID(fromDateRow id: String) -> String {
    String(id.dropFirst(ChatDateRowPrefix.count))
}

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
    let isGroup: Bool
    let showSeen: Bool
    let seenAvatarURL: String?
    let pinnedIds: Set<String>
    let readCursors: [String: String]
    let pulsingId: String?
    let scrollToId: String?
    let isLoadingMore: Bool
    let bottomInset: CGFloat
    let scrollToBottomToken: Int
    let scrollProxy: ChatScrollProxy?
    let composerHeight: CGFloat
    let jumpMentionCount: Int
    let jumpReactionCount: Int
    var onJumpToMention: (() -> String?)? = nil
    var onJumpToReaction: (() -> String?)? = nil
    @Binding var isAtBottom: Bool
    let onScrollToIdConsumed: () -> Void
    let onTopReached: () -> Void
    let onCellLongPressed: (Message, CGRect) -> Void
    let isMe: (Message) -> Bool
    let onReply: (Message) -> Void
    let swipeState: ChatSwipeState
    var onFirstVisibleDateChanged: ((Date?) -> Void)?
    /// Height of the composer overlay for contentInset (scroll-behind blur).
    /// Rotated table: visual-bottom = contentInset.top.
    var composerOverlayHeight: CGFloat = 0
    /// Height of the pinned banner overlay.
    /// Rotated table: visual-top = contentInset.bottom.
    var bannerOverlayHeight: CGFloat = 0
    var unreadCount: Int = 0
    var myReadAt: String? = nil
    let cellBuilder: (Message, Int) -> Cell
    var groupCellBuilder: (([Message]) -> AnyView)? = nil

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
        // `.never` — the enclosing SwiftUI VStack already controls
        // the list's frame (composer below, nav bar above). Letting
        // UIKit auto-adjust for safe areas causes contentOffset to
        // shift when sibling views animate (jump-to-bottom button
        // appearing, reply bar in/out), which on a rotated table
        // shows up as a snap back toward the latest-message edge
        // mid-scroll.
        // `.never` — we manage content insets manually for the
        // frosted overlay (composer scrolls-behind) effect.
        tv.contentInsetAdjustmentBehavior = .never
        // Rotated table: visual-bottom = contentInset.top,
        // visual-top = contentInset.bottom.
        // Nav bar height comes from adjustedContentInset automatically
        // when contentInsetAdjustmentBehavior = .always, but we use
        // .never + manual insets to avoid animation glitches. So we
        // add the safe area top (nav bar) to contentInset.bottom
        // (rotated visual-top).
        let safeTop = tv.superview?.safeAreaInsets.top ?? 0
        tv.contentInset = UIEdgeInsets(
            top: composerOverlayHeight,
            left: 0,
            bottom: bannerOverlayHeight + safeTop,
            right: 0
        )
        tv.scrollsToTop = false
        // Self-sizing cells — UIHostingConfiguration reports its
        // intrinsic height.
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 80
        tv.sectionHeaderHeight = 0
        tv.estimatedSectionHeaderHeight = 0
        tv.sectionHeaderTopPadding = 0
        tv.sectionFooterHeight = 0
        tv.estimatedSectionFooterHeight = 0

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

        // Context-menu trigger.
        //
        // iOS / iPadOS: long-press — our own UILongPressGestureRecognizer
        // because the default system threshold (~0.5s) feels sluggish
        // next to Messages / Telegram. 0.28s matches their cadence.
        //
        // Mac Catalyst: right-click. Previously we used a
        // UITapGestureRecognizer with `buttonMaskRequired = .secondary`,
        // but that combination is unreliable on Catalyst — depending on
        // build target and OS version the recognizer either never fires
        // or loses out to the table view's internal selection gesture.
        // Switch to the UIKit-standard path:
        // `UITableViewDelegate.contextMenuConfigurationForRowAt` fires
        // on right-click out of the box, with no gesture-recognizer
        // collisions. We fire the custom SwiftUI overlay as a side
        // effect and return nil so the system doesn't present its own
        // dim/lift menu UI — we already have our own.
        #if !targetEnvironment(macCatalyst)
        let lp = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        lp.minimumPressDuration = 0.28
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        tv.addGestureRecognizer(lp)
        #endif

        // Horizontal swipe-to-reply. Attached at the table level (not
        // per-bubble) so we can coordinate with the table's own pan
        // via UIGestureRecognizerDelegate — SwiftUI's
        // `simultaneousGesture(DragGesture)` can't, which is why
        // dragging on a bubble previously blocked vertical scroll.
        //
        // `HorizontalPanGestureRecognizer` fails the gesture early
        // when the drag is vertical-dominant, so the table pan takes
        // over and scroll feels native.
        let swipePan = HorizontalPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipePan(_:))
        )
        swipePan.delegate = context.coordinator
        swipePan.cancelsTouchesInView = false
        tv.addGestureRecognizer(swipePan)

        tv.delegate = context.coordinator
        tv.prefetchDataSource = context.coordinator
        context.coordinator.attach(table: tv)
        scrollProxy?.tableView = tv
        context.coordinator.apply(items: items, typingUsers: typingUsers, showSeen: showSeen, animated: false)
        return tv
    }

    func updateUIView(_ tv: UITableView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        scrollProxy?.tableView = tv

        // Setup jump button on first superview availability
        if let superview = tv.superview, coord.jumpHostVC == nil {
            coord.setupJumpButtons(in: superview)
        }
        coord.consumeMention = onJumpToMention
        coord.consumeReaction = onJumpToReaction
        coord.updateJumpButtons(
            isAtBottom: isAtBottom,
            composerHeight: composerHeight,
            unreadCount: unreadCount,
            mentionCount: jumpMentionCount,
            reactionCount: jumpReactionCount
        )

        let prevIDs = coord.lastItems.map(\.id)
        let newIDs = items.map(\.id)

        // In-place edits (reactions, edit, unsend): detect which rows
        // changed content (same ID, different value). Reconfigure runs
        // AFTER the structural snapshot apply to avoid being overshadowed.
        var contentChangedIDs: [String] = []
        if !coord.lastItems.isEmpty {
            let prevById = Dictionary(uniqueKeysWithValues: coord.lastItems.map { ($0.id, $0) })
            contentChangedIDs = items.compactMap { m -> String? in
                if let prev = prevById[m.id], prev != m { return m.id }
                return nil
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
        let prevOffset = tv.contentOffset.y + tv.contentInset.top
        let wasNearBottom = tv.bounds.height > 0 && prevOffset < 200

        // Apply the new snapshot. Animated for new-message arrivals +
        // typing toggles; static for bulk reloads (cache hydration,
        // pagination which has its own offset compensation).
        //
        // Skip entirely when nothing relevant changed — SwiftUI
        // re-renders ChatView on every isAtBottom flip, keyboard
        // tick, pulse, reply-bar toggle, etc. Rebuilding + applying
        // an identical diffable snapshot on every tick is wasted
        // work and can briefly disturb the scroll.
        let typingToggled = coord.lastTypingUsers != typingUsers
        let seenToggled = coord.lastShowSeen != showSeen
        let unreadChanged = coord.lastUnreadCount != unreadCount || coord.lastMyReadAt != myReadAt
        let itemsChanged = coord.lastItems.map(\.id) != newIDs
        if itemsChanged || typingToggled || seenToggled || unreadChanged {
            coord.lastUnreadCount = unreadCount
            coord.lastMyReadAt = myReadAt
            let animate = isAppend || typingToggled
            coord.apply(items: items, typingUsers: typingUsers, showSeen: showSeen, animated: animate)
        } else {
            coord.lastItems = items
            coord.itemById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        }

        // Reconfigure content-changed rows AFTER the structural apply
        // so the update is never overshadowed by a concurrent snapshot.
        // Force immediate layout so UIHostingConfiguration commits the
        // new SwiftUI content without waiting for the next display link.
        if !contentChangedIDs.isEmpty {
            coord.lastItems = items
            coord.itemById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            coord.reconfigure(ids: contentChangedIDs)
            tv.layoutIfNeeded()
        }

        // Pinned changes: reconfigure so the pin badge flips without
        // a full snapshot apply.
        if coord.lastPinnedIds != pinnedIds {
            let diff = coord.lastPinnedIds.symmetricDifference(pinnedIds)
            coord.lastPinnedIds = pinnedIds
            coord.reconfigure(ids: Array(diff))
        }

        // Read cursors: only reconfigure outgoing messages — incoming
        // bubbles don't render seen-by avatars, so touching every row
        // was O(n) wasted work.
        if coord.lastReadCursors != readCursors {
            coord.lastReadCursors = readCursors
            let outgoingIds = items.filter { isMe($0) }.map(\.id)
            coord.reconfigure(ids: outgoingIds)
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

        // Keyboard-driven scroll-to-bottom: we used to snap to the
        // latest message every time the keyboard appeared, but that
        // hijacked the user's reading position whenever they tapped
        // into the composer from mid-conversation. Drop the auto-
        // scroll entirely — the caller bumps `scrollToBottomToken`
        // explicitly from `onSend`, which is the only time we want
        // to force the list back to the bottom.
        //
        // `keyboard.height` is still tracked here (via `bottomInset`)
        // because other layout paths may care; `keyboardWasOpen` is
        // still updated for parity with any future opt-in behaviour.
        let isOpen = bottomInset > 0.5
        if coord.keyboardWasOpen != isOpen {
            coord.keyboardWasOpen = isOpen
        }
        coord.lastBottomInset = bottomInset

        // Sync overlay insets for scroll-behind blur.
        // Rotated table: visual-bottom = .top, visual-top = .bottom.
        let safeTop = tv.superview?.safeAreaInsets.top ?? 0
        let wantedTop = composerOverlayHeight
        let wantedBottom = bannerOverlayHeight + safeTop
        if abs(tv.contentInset.top - wantedTop) > 0.5
            || abs(tv.contentInset.bottom - wantedBottom) > 0.5 {
            tv.contentInset = UIEdgeInsets(
                top: wantedTop, left: 0,
                bottom: wantedBottom, right: 0
            )
        }

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
            // If there's an unread divider, scroll to it so the user
            // lands right at the boundary between read and unread.
            // Otherwise park at (0,0) as before.
            let hasUnread = unreadCount > 0
            DispatchQueue.main.async { [weak tv, weak coord] in
                guard let tv, let coord else { return }
                if hasUnread {
                    coord.scrollTo(id: ChatUnreadDividerID, in: tv, animated: false)
                } else {
                    // Rest point with contentInset is -inset.top, not (0,0).
                    let rest = CGPoint(x: 0, y: -tv.contentInset.top)
                    tv.setContentOffset(rest, animated: false)
                }
            }
        }
        _ = (wasNearBottom, prevHeight, prevOffset, isPrepend)

        // Jump-to-id (reply pulse + message search).
        // Only consume the id when scroll succeeds — if the target
        // message hasn't loaded yet, keep it pending so the next
        // updateUIView cycle retries automatically once pages arrive.
        if let id = scrollToId {
            DispatchQueue.main.async {
                if coord.scrollTo(id: id, in: tv, animated: true) {
                    onScrollToIdConsumed()
                }
            }
        }

        // Imperative scroll-to-bottom token (send button, etc.).
        // Must run AFTER contentInset sync above, and synchronously —
        // async dispatch loses the race against preference-triggered
        // re-renders that reset contentOffset.
        if coord.lastScrollToBottomToken != scrollToBottomToken {
            coord.lastScrollToBottomToken = scrollToBottomToken
            coord.scrollToBottom(in: tv, animated: true)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSourcePrefetching, UIGestureRecognizerDelegate {
        var parent: ChatMessagesList
        fileprivate weak var table: UITableView?

        private var dataSource: UITableViewDiffableDataSource<String, String>!

        var lastItems: [Message] = []
        var itemById: [String: Message] = [:]
        var lastTypingUsers: [String] = []
        var lastShowSeen: Bool = false
        var lastPinnedIds: Set<String> = []
        var lastReadCursors: [String: String] = [:]
        var lastPulsingId: String?
        var lastBottomInset: CGFloat = 0
        var keyboardWasOpen: Bool = false
        var lastScrollToBottomToken: Int = 0
        var lastUnreadCount: Int = 0
        var lastMyReadAt: String?
        var didInitialScroll = false
        var initialScrollAt: Date?
        /// Group row ID → ordered message IDs in that group.
        var groupById: [String: [String]] = [:]
        /// Individual message ID → the group row ID it belongs to.
        var groupIdForMessage: [String: String] = [:]
        private var loadingMore = false

        // Date pill: cached ISO8601 formatter for parsing created_at
        private let isoFormatter = ISO8601DateFormatter()
        /// Last date reported to the date pill callback, used to avoid
        /// redundant dispatches on every scroll tick.
        private var lastReportedDate: Date?

        // Swipe-to-reply state
        private var swipeActiveId: String?
        private var swipeActiveIsMe: Bool = false
        private var swipeTriggered: Bool = false
        private let swipeThreshold: CGFloat = 60
        /// Captured when we engage a swipe so we can re-enable it on
        /// end. Nav-pop is disabled for the duration of the swipe
        /// because it otherwise hijacks any rightward drag on a
        /// left-aligned (incoming) bubble and prevents reply-swipe.
        private weak var suspendedNavPopGR: UIGestureRecognizer?

        // MARK: Jump button (UIHostingController-hosted JumpButtonStack)
        fileprivate var jumpHostVC: UIHostingController<JumpButtonStack>?
        private var jumpBottomConstraint: NSLayoutConstraint?
        var isProgrammaticScroll = false

        /// Callbacks that consume the next pending ID and return it.
        /// Coordinator scrolls directly to the returned ID.
        var consumeMention: (() -> String?)?
        var consumeReaction: (() -> String?)?

        init(parent: ChatMessagesList) {
            self.parent = parent
        }

        func setupJumpButtons(in container: UIView) {
            guard jumpHostVC == nil else { return }

            let stack = JumpButtonStack(
                isAtBottom: true,
                unreadCount: 0,
                mentionCount: 0,
                reactionCount: 0,
                onJumpToBottom: { [weak self] in self?.scrollToBottomTapped() },
                onJumpToMention: { [weak self] in self?.mentionTapped() },
                onJumpToReaction: { [weak self] in self?.reactionTapped() }
            )
            let host = UIHostingController(rootView: stack)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize

            container.addSubview(host.view)
            let bottomConstraint = host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
            NSLayoutConstraint.activate([
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                bottomConstraint
            ])
            jumpBottomConstraint = bottomConstraint
            jumpHostVC = host
        }

        func updateJumpButtons(isAtBottom: Bool, composerHeight: CGFloat,
                               unreadCount: Int, mentionCount: Int, reactionCount: Int) {
            guard let host = jumpHostVC else { return }
            host.rootView = JumpButtonStack(
                isAtBottom: isAtBottom,
                unreadCount: unreadCount,
                mentionCount: mentionCount,
                reactionCount: reactionCount,
                onJumpToBottom: { [weak self] in self?.scrollToBottomTapped() },
                onJumpToMention: { [weak self] in self?.mentionTapped() },
                onJumpToReaction: { [weak self] in self?.reactionTapped() }
            )
            jumpBottomConstraint?.constant = -(composerHeight + 8)
        }

        private func scrollToBottomTapped() {
            Haptics.selection()
            guard let tv = table else { return }

            // If there's an unread divider, scroll to it first
            if parent.unreadCount > 0,
               scrollTo(id: ChatUnreadDividerID, in: tv, animated: true) {
                return
            }

            // Otherwise scroll to bottom
            let target = CGPoint(x: 0, y: -tv.contentInset.top)
            scrollToOffset(target, in: tv)
        }

        private func mentionTapped() {
            Haptics.selection()
            guard let tv = table, let id = consumeMention?() else { return }
            _ = scrollTo(id: id, in: tv, animated: true)
        }

        private func reactionTapped() {
            Haptics.selection()
            guard let tv = table, let id = consumeReaction?() else { return }
            _ = scrollTo(id: id, in: tv, animated: true)
        }

        private func scrollToOffset(_ target: CGPoint, in tv: UITableView) {
            isProgrammaticScroll = true
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                tv.contentOffset = target
            } completion: { [weak self] _ in
                self?.isProgrammaticScroll = false
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isAtBottom = true
                }
            }
        }

        // Private cell reuse identifier. All rows use a single
        // UIHostingConfiguration, so one class is enough. Instance-
        // level rather than static because Swift forbids static
        // stored properties inside a nested generic type.
        private let cellID = "ChatMessageCell"

        func attach(table: UITableView) {
            self.table = table
            table.register(UITableViewCell.self, forCellReuseIdentifier: cellID)

            dataSource = UITableViewDiffableDataSource<String, String>(tableView: table) { [weak self] tv, indexPath, id in
                let cell = tv.dequeueReusableCell(withIdentifier: self?.cellID ?? "ChatMessageCell", for: indexPath)
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
            if chatIsDateRow(id) {
                let sectionID = chatSectionID(fromDateRow: id)
                let label = ChatSectioning.label(for: sectionID)
                cell.contentConfiguration = UIHostingConfiguration {
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
                .margins(.horizontal, 12)
                .margins(.vertical, 2)
                return
            }
            if id == ChatTypingRowID {
                let logins = lastTypingUsers
                let isGroup = parent.isGroup
                cell.contentConfiguration = UIHostingConfiguration {
                    TypingIndicatorRow(logins: logins, isGroup: isGroup)
                        .rotationEffect(.degrees(180))
                }
                .margins(.horizontal, 12)
                .margins(.vertical, 2)
                return
            }
            if id == ChatSeenRowID {
                let avatarURL = parent.seenAvatarURL
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack {
                        Spacer()
                        AvatarView(url: avatarURL, size: 20)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1))
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .rotationEffect(.degrees(180))
                }
                .margins(.horizontal, 12)
                .margins(.vertical, 2)
                return
            }
            if id == ChatUnreadDividerID {
                let count = parent.unreadCount
                cell.contentConfiguration = UIHostingConfiguration {
                    UnreadDividerRow(count: count)
                        .rotationEffect(.degrees(180))
                }
                .margins(.all, 0)
                return
            }
            // Grouped sender cell: multiple messages rendered as one row.
            if id.hasPrefix(ChatSenderGrouping.groupPrefix) {
                guard let messageIDs = groupById[id] else { return }
                let messages = messageIDs.compactMap { itemById[$0] }
                guard !messages.isEmpty else { return }
                let swipeState = parent.swipeState
                if let builder = parent.groupCellBuilder {
                    cell.contentConfiguration = UIHostingConfiguration {
                        builder(messages)
                            .rotationEffect(.degrees(180))
                            .environmentObject(swipeState)
                    }
                    .margins(.horizontal, 8)
                    .margins(.vertical, 0)
                    .minSize(width: 0, height: 0)
                }
                return
            }
            guard let msg = itemById[id] else { return }
            let idx = lastItems.firstIndex(where: { $0.id == id }) ?? indexPath.row
            let swipeState = parent.swipeState
            // Zero cell margins AND zero min-size. UIHostingConfiguration
            // ships with a default minimum height (~44pt for tap-target
            // friendliness) that silently inflated short bubbles — that
            // was the source of the "chỗ đúng chỗ sai" feeling: short
            // messages had the row padded up to the minimum, longer
            // ones used their natural intrinsic height. Pinning min
            // size to 0 makes every row exactly its content size, so
            // `.padding(.top, 2 / 14)` in ChatView.messageRow is the
            // only spacing source.
            cell.contentConfiguration = UIHostingConfiguration {
                parent.cellBuilder(msg, idx)
                    .rotationEffect(.degrees(180))
                    .environmentObject(swipeState)
            }
            .margins(.horizontal, 8)
            .margins(.vertical, 0)
            .minSize(width: 0, height: 0)
        }

        // MARK: Snapshot application

        func apply(
            items: [Message],
            typingUsers: [String],
            showSeen: Bool,
            animated: Bool
        ) {
            lastItems = items
            itemById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
            let dayGroups = ChatSectioning.groupByDay(items)
            // Reset group maps for this snapshot.
            groupById.removeAll()
            groupIdForMessage.removeAll()
            // Trailing rows (typing indicator / seen avatar row) belong
            // in data-space AFTER the latest message, so in the
            // rotated table they appear BELOW the latest bubble. In
            // rotated-snapshot space they go to section 0 as rows
            // BEFORE the latest message — i.e. prepended.
            var trailingRowsForLatestSection: [String] = []
            if !typingUsers.isEmpty { trailingRowsForLatestSection.append(ChatTypingRowID) }
            if showSeen { trailingRowsForLatestSection.append(ChatSeenRowID) }

            // Determine where the unread divider belongs. In data
            // space, items are oldest-first; in snapshot space (after
            // reversal) they are newest-first. We want the divider
            // between the last-read message and the first unread one.
            // A message is "read" when its created_at <= myReadAt.
            let unreadDividerMsgId: String? = {
                guard parent.unreadCount > 0 else { return nil }
                guard let readAt = parent.myReadAt else {
                    // myReadAt nil = never opened → all messages unread.
                    // Return special sentinel so divider goes at the very top.
                    return "__all_unread__"
                }
                // items (lastItems) are oldest-first. Walk from the
                // END (newest) toward the START (oldest) and find the
                // first message whose created_at <= readAt — that's
                // the last read message. The divider goes just after
                // it in the original array (= just before it in the
                // reversed snapshot rows).
                for msg in lastItems.reversed() {
                    if (msg.created_at ?? "") <= readAt {
                        return msg.id
                    }
                }
                return nil
            }()

            for (offset, dayGroup) in dayGroups.reversed().enumerated() {
                snap.appendSections([dayGroup.sectionID])

                // Run sender grouping within this day section.
                let grouped = ChatSenderGrouping.group(
                    messageIDs: dayGroup.messageIDs,
                    lookup: { itemById[$0] },
                    isMe: { parent.isMe($0) },
                    isGroup: parent.isGroup
                )

                // Build row IDs (reversed for rotated table).
                var rows: [String] = []
                for item in grouped.reversed() {
                    switch item {
                    case .single(let id):
                        rows.append(id)
                    case .group(let g):
                        rows.append(g.id)
                        groupById[g.id] = g.messageIDs
                        for mid in g.messageIDs {
                            groupIdForMessage[mid] = g.id
                        }
                    }
                }

                if offset == 0 {
                    rows = trailingRowsForLatestSection + rows
                }
                // Insert unread divider if it belongs in this section.
                // For grouped messages, the unread divider targets a
                // message ID. If that ID is inside a group, we place
                // the divider after the group row instead.
                if let targetId = unreadDividerMsgId {
                    if targetId == "__all_unread__" {
                        // myReadAt nil → all unread. Place divider at
                        // the end of the last section (= visual top).
                        if offset == dayGroups.count - 1 {
                            rows.append(ChatUnreadDividerID)
                        }
                    } else {
                        // Resolve target: if the message is inside a
                        // group, use the group row ID instead.
                        let resolvedTarget = groupIdForMessage[targetId] ?? targetId
                        if let idx = rows.firstIndex(of: resolvedTarget) {
                            // Insert AFTER last-read msg in reversed array
                            // = visually ABOVE it in rotated table
                            rows.insert(ChatUnreadDividerID, at: idx + 1)
                        }
                    }
                }
                // Append the date pill at the END of the section
                // (rotation-space bottom of section = visually TOP of
                // the day's messages). Regular row — not a section
                // footer — so the pill scrolls with content.
                rows.append(chatDateRowID(for: dayGroup.sectionID))
                snap.appendItems(rows, toSection: dayGroup.sectionID)
            }
            dataSource.apply(snap, animatingDifferences: animated)
        }

        func reconfigure(ids: [String]) {
            guard !ids.isEmpty else { return }
            // Translate individual message IDs that are inside groups
            // to their group row IDs (the snapshot only knows group IDs).
            var resolved: Set<String> = []
            for id in ids {
                if let gid = groupIdForMessage[id] {
                    resolved.insert(gid)
                } else {
                    resolved.insert(id)
                }
            }
            var snap = dataSource.snapshot()
            let present = resolved.filter { snap.itemIdentifiers.contains($0) }
            guard !present.isEmpty else { return }
            snap.reloadItems(Array(present))
            dataSource.apply(snap, animatingDifferences: false)
        }

        // MARK: Scrolling

        /// "Bottom" visually = section 0, row 0 in the rotated table.
        func scrollToBottom(in tv: UITableView, animated: Bool) {
            // Rotated table: visual bottom (newest messages) is at
            // contentOffset.y == -contentInset.top (adjustment behavior
            // is .never, so adjustedContentInset may include unexpected
            // safe-area additions).
            let target = CGPoint(x: 0, y: -tv.contentInset.top)
            tv.setContentOffset(target, animated: animated)
        }

        /// Returns true if the row was found and scrolled to.
        @discardableResult
        func scrollTo(id: String, in tv: UITableView, animated: Bool) -> Bool {
            if let indexPath = dataSource.indexPath(for: id) {
                tv.scrollToRow(at: indexPath, at: .middle, animated: animated)
                return true
            }
            // Fallback: the message may be inside a grouped cell.
            if let groupId = groupIdForMessage[id],
               let indexPath = dataSource.indexPath(for: groupId) {
                tv.scrollToRow(at: indexPath, at: .middle, animated: animated)
                return true
            }
            return false
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

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }

        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 0 }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Skip isAtBottom updates during programmatic scroll to
            // prevent re-render → contentInset change → offset reset.
            guard !isProgrammaticScroll else { return }

            let offset = scrollView.contentOffset.y + scrollView.contentInset.top
            let current = parent.isAtBottom
            let next: Bool
            if current {
                next = offset < 120
            } else {
                next = offset < 40
            }
            if current != next {
                let v = next
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isAtBottom = v
                }
            }

            // Pagination: approaching the far end of the content (=
            // visually the TOP of the screen, = oldest messages).
            if !loadingMore {
                let distanceToEnd = scrollView.contentSize.height
                    - (scrollView.contentOffset.y + scrollView.bounds.height)
                if distanceToEnd < 600 { fireLoadMore() }
            }

            // Date pill: find the oldest visible message (visually at
            // the top). In the rotated table, `indexPathsForVisibleRows`
            // is sorted by ascending IndexPath — `.last` is the highest
            // section + row = the oldest message on screen.
            guard let tv = scrollView as? UITableView,
                  let visiblePaths = tv.indexPathsForVisibleRows,
                  !visiblePaths.isEmpty else { return }
            // Walk from the last visible path backwards to find the
            // first real message row (skip date pills and synthetic rows).
            var foundDate: Date?
            for path in visiblePaths.reversed() {
                guard let id = dataSource.itemIdentifier(for: path) else { continue }
                if id == ChatTypingRowID || id == ChatSeenRowID || id == ChatUnreadDividerID || chatIsDateRow(id) { continue }
                // Resolve group row to its first message for date.
                let resolvedId: String
                if id.hasPrefix(ChatSenderGrouping.groupPrefix),
                   let mids = groupById[id], let fid = mids.first {
                    resolvedId = fid
                } else {
                    resolvedId = id
                }
                if let msg = itemById[resolvedId],
                   let raw = msg.created_at,
                   let d = isoFormatter.date(from: raw) {
                    foundDate = d
                    break
                }
            }
            // Only notify when the calendar day actually changes —
            // avoids churning SwiftUI state on every scroll tick.
            let cal = Calendar.current
            let changed: Bool
            if let prev = lastReportedDate, let next = foundDate {
                changed = !cal.isDate(prev, inSameDayAs: next)
            } else {
                changed = (lastReportedDate == nil) != (foundDate == nil)
            }
            if changed {
                lastReportedDate = foundDate
                let cb = parent.onFirstVisibleDateChanged
                let date = foundDate
                DispatchQueue.main.async { cb?(date) }
            }

        }

        private func fireLoadMore() {
            loadingMore = true
            parent.onTopReached()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.loadingMore = false
            }
        }

        // MARK: Long-press → menu

        // MARK: Swipe-to-reply

        @objc fileprivate func handleSwipePan(_ gr: UIPanGestureRecognizer) {
            guard let tv = table else { return }

            switch gr.state {
            case .began:
                let point = gr.location(in: tv)
                guard let indexPath = tv.indexPathForRow(at: point),
                      let id = dataSource.itemIdentifier(for: indexPath) else {
                    gr.state = .cancelled
                    return
                }
                // Skip synthetic rows.
                if id == ChatTypingRowID || id == ChatSeenRowID || id == ChatUnreadDividerID || chatIsDateRow(id) {
                    gr.state = .cancelled
                    return
                }
                // Grouped cell: use the last message for swipe-to-reply.
                if id.hasPrefix(ChatSenderGrouping.groupPrefix) {
                    guard let messageIDs = groupById[id],
                          let lastId = messageIDs.last,
                          let msg = itemById[lastId] else {
                        gr.state = .cancelled
                        return
                    }
                    swipeActiveId = lastId
                    swipeActiveIsMe = parent.isMe(msg)
                    swipeTriggered = false
                    let tablePan = tv.panGestureRecognizer
                    tablePan.isEnabled = false
                    tablePan.isEnabled = true
                    if let nav = findNavPopRecognizer(), nav.isEnabled {
                        nav.isEnabled = false
                        suspendedNavPopGR = nav
                    }
                    parent.swipeState.messageId = lastId
                    parent.swipeState.offsetX = 0
                    return
                }
                guard let msg = itemById[id] else {
                    gr.state = .cancelled
                    return
                }
                // System messages don't reply.
                if let t = msg.type, t != "user" {
                    gr.state = .cancelled
                    return
                }
                swipeActiveId = id
                swipeActiveIsMe = parent.isMe(msg)
                swipeTriggered = false
                // Cancel the table's pan so it doesn't scroll while
                // we're driving a horizontal swipe on this bubble.
                let tablePan = tv.panGestureRecognizer
                tablePan.isEnabled = false
                tablePan.isEnabled = true
                // Disable the nav controller's interactive-pop for
                // the duration of the swipe. On incoming bubbles the
                // reply-swipe is a rightward drag, same direction
                // as swipe-back — without this the nav controller
                // wins and the screen pops. User can still go back
                // via the nav bar button.
                if let nav = findNavPopRecognizer(), nav.isEnabled {
                    nav.isEnabled = false
                    suspendedNavPopGR = nav
                }
                parent.swipeState.messageId = id
                parent.swipeState.offsetX = 0

            case .changed:
                guard swipeActiveId != nil else { return }
                // Translate in window coords so the table's 180°
                // rotation doesn't invert our dx.
                let dx = gr.translation(in: tv.superview ?? tv).x
                let clamped: CGFloat
                if swipeActiveIsMe {
                    clamped = min(0, max(-swipeThreshold * 1.4, dx))
                } else {
                    clamped = max(0, min(swipeThreshold * 1.4, dx))
                }
                parent.swipeState.offsetX = clamped
                if !swipeTriggered, abs(clamped) >= swipeThreshold {
                    swipeTriggered = true
                    // A firmer thump when we cross the commit
                    // threshold — selection-style taps on device are
                    // easy to miss in motion. Matches Messages.app's
                    // swipe-to-reply feel.
                    Haptics.impact(.medium)
                } else if swipeTriggered, abs(clamped) < swipeThreshold {
                    swipeTriggered = false
                }

            case .ended, .cancelled, .failed:
                let shouldFire = swipeTriggered
                let firedId = swipeActiveId
                swipeTriggered = false
                swipeActiveId = nil
                // Always restore nav-pop even on cancel/fail paths.
                suspendedNavPopGR?.isEnabled = true
                suspendedNavPopGR = nil
                // Spring back via SwiftUI animation so the bubble
                // eases home.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    parent.swipeState.offsetX = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    if self.parent.swipeState.messageId == firedId {
                        self.parent.swipeState.messageId = nil
                    }
                }
                if shouldFire,
                   let id = firedId,
                   let msg = itemById[id] {
                    parent.onReply(msg)
                }

            default:
                break
            }
        }

        /// Walks the responder chain from the table view up to the
        /// enclosing `UINavigationController` and returns its
        /// `interactivePopGestureRecognizer`. We disable that
        /// recognizer while a swipe-to-reply is active so incoming
        /// bubble swipes don't pop the screen.
        private func findNavPopRecognizer() -> UIGestureRecognizer? {
            var responder: UIResponder? = table
            while let r = responder {
                if let vc = r as? UIViewController {
                    if let nav = vc as? UINavigationController {
                        return nav.interactivePopGestureRecognizer
                    }
                    if let nav = vc.navigationController {
                        return nav.interactivePopGestureRecognizer
                    }
                }
                responder = r.next
            }
            return nil
        }

        // Allow the swipe pan and the table's pan to coexist during
        // the decision phase — once our recognizer decides it's a
        // horizontal drag we cancel the table pan in `.began`. We
        // explicitly do NOT allow simultaneous recognition with the
        // navigation controller's edge-swipe-back gesture, otherwise
        // starting a swipe on an incoming (left-aligned) bubble near
        // the screen edge pops the navigation stack.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer { return false }
            return true
        }

        // No delegate-level priority vs. nav-pop — that broke the
        // edge-swipe-to-go-back gesture entirely by forcing the nav
        // pop to wait for ours unconditionally. Instead, the
        // `shouldBegin` check below excludes a ~24pt zone along the
        // leading edge so nav-pop stays responsible for that band
        // while the rest of the row belongs to reply-swipe.

        // Decide direction at the last possible moment — when the
        // pan wants to transition to `.began`. By now translation is
        // ~10pt, enough to tell vertical from horizontal. Returning
        // false fails the gesture so the table's own pan keeps
        // scrolling for vertical drags.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? HorizontalPanGestureRecognizer,
                  let v = pan.view else { return true }
            let t = pan.translation(in: v.superview ?? v)
            // If somehow called before any motion, allow; the .began
            // handler will locate the target cell and bail on missing.
            if abs(t.x) < 1 && abs(t.y) < 1 { return true }
            // Strictly horizontal-dominant only — otherwise let the
            // table scroll.
            guard abs(t.x) > abs(t.y) * 1.2 else { return false }
            // Reserve a strip along the leading edge for the nav
            // controller's swipe-back. Computing start.x from
            // (current - translation) rather than saving it in
            // touchesBegan keeps this self-contained.
            let loc = pan.location(in: v)
            let startX = loc.x - t.x
            if startX < 24 { return false }
            return true
        }

        @objc fileprivate func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let tv = table else { return }
            let point = gr.location(in: tv)
            presentMenu(at: point, in: tv, withHaptic: true)
        }

        #if targetEnvironment(macCatalyst)
        /// Catalyst right-click path. Returning `nil` suppresses the
        /// system's default dim-and-lift menu UI — our SwiftUI overlay
        /// is the one the user actually sees. No haptic: a mouse
        /// right-click never buzzes.
        func tableView(
            _ tableView: UITableView,
            contextMenuConfigurationForRowAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            presentMenu(at: point, in: tableView, withHaptic: false)
            return nil
        }
        #endif

        private func presentMenu(at point: CGPoint, in tv: UITableView, withHaptic haptic: Bool) {
            guard let indexPath = tv.indexPathForRow(at: point) else { return }
            guard let cell = tv.cellForRow(at: indexPath) else { return }
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
            if id == ChatTypingRowID || id == ChatSeenRowID || id == ChatUnreadDividerID { return }
            if chatIsDateRow(id) { return }
            // Grouped cell: find which message was tapped by touch Y.
            if id.hasPrefix(ChatSenderGrouping.groupPrefix) {
                guard let messageIDs = groupById[id], !messageIDs.isEmpty else { return }
                let touchInWindow = tv.convert(point, to: nil)
                // Find the message whose cached bubble frame contains the touch Y
                var targetMsg: Message?
                for mid in messageIDs {
                    if let f = BubbleFrameCache.shared.frame(for: mid),
                       touchInWindow.y >= f.minY && touchInWindow.y <= f.maxY {
                        targetMsg = itemById[mid]
                        break
                    }
                }
                // Fallback: last message if no cache hit
                if targetMsg == nil, let lastId = messageIDs.last {
                    targetMsg = itemById[lastId]
                }
                guard let msg = targetMsg else { return }
                if haptic { Haptics.impact(.medium) }
                let frame = BubbleFrameCache.shared.frame(for: msg.id)
                    ?? cell.convert(cell.bounds, to: nil)
                parent.onCellLongPressed(msg, frame)
                return
            }
            guard let msg = itemById[id] else { return }
            if haptic { Haptics.impact(.medium) }
            // Use cached bubble frame for exact position, fallback to cell frame
            let frame = BubbleFrameCache.shared.frame(for: msg.id)
                ?? cell.convert(cell.bounds, to: nil)
            parent.onCellLongPressed(msg, frame)
        }

        // MARK: Prefetch

        private func imageURLs(at indexPaths: [IndexPath]) -> [URL] {
            var urls: [URL] = []
            for ip in indexPaths {
                guard let id = dataSource.itemIdentifier(for: ip) else { continue }
                if id == ChatTypingRowID || id == ChatSeenRowID || id == ChatUnreadDividerID { continue }
                if chatIsDateRow(id) { continue }
                // For group rows, collect URLs from all messages in the group.
                if id.hasPrefix(ChatSenderGrouping.groupPrefix) {
                    guard let mids = groupById[id] else { continue }
                    for mid in mids {
                        guard let msg = itemById[mid] else { continue }
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
                    continue
                }
                guard let msg = itemById[id] else { continue }
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

// MARK: - Unread divider row

struct UnreadDividerRow: View {
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color("AccentColor").opacity(0.2)).frame(height: 1)
            Text("\(count) unread messages")
                .font(.caption2.weight(.semibold))
                .foregroundColor(Color("AccentColor"))
                .fixedSize()
            Rectangle().fill(Color("AccentColor").opacity(0.2)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Horizontal-dominant pan recognizer

/// Marker subclass — direction filtering happens in the Coordinator's
/// `gestureRecognizerShouldBegin(_:)`, which is UIKit's natural hook
/// for deciding whether a pan may transition from `.possible` to
/// `.began`. Failing from `touchesMoved` (our first attempt) was
/// too late: UIKit had already transitioned the state, so vertical
/// drags leaked through as swipes.
private final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {}

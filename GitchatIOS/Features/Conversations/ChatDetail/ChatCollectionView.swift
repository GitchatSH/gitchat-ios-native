import SwiftUI
import UIKit

/// Synthetic snapshot id used for the typing-indicator row at the
/// bottom of the conversation.
let ChatTypingRowID = "__typing__"

/// UICollectionView-backed chat list. Wraps a compositional layout with
/// self-sizing UIHostingConfiguration cells and a diffable data source so
/// rows are recycled by UIKit instead of re-instantiated by SwiftUI on
/// every body invocation. This is what real chat apps (Telegram, iMessage)
/// use under the hood — much smoother than `LazyVStack` in `ScrollView`
/// for rich content with images and long lists.
struct ChatCollectionView<Cell: View>: UIViewRepresentable {
    let items: [Message]
    let typingUsers: [String]
    let pinnedIds: Set<String>
    let pulsingId: String?
    let scrollToId: String?
    let isLoadingMore: Bool
    let bottomInset: CGFloat
    let scrollToBottomToken: Int
    @Binding var isAtBottom: Bool
    let onScrollToIdConsumed: () -> Void
    let onTopReached: () -> Void
    let cellBuilder: (Message, Int) -> Cell

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(80)
                )
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(80)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 4
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(40)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.delegate = context.coordinator
        cv.keyboardDismissMode = .interactive
        cv.alwaysBounceVertical = true
        cv.showsVerticalScrollIndicator = false
        cv.contentInsetAdjustmentBehavior = .automatic

        context.coordinator.attach(cv: cv)
        context.coordinator.apply(items: items, typingUsers: typingUsers, animated: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        let prevIDs = coord.lastItems.map(\.id)
        let newIDs = items.map(\.id)
        let prevHeight = cv.contentSize.height
        let prevOffset = cv.contentOffset.y
        // Be generous about "near bottom" so a newly arrived message
        // always pulls the list down if the user is parked at the end.
        let wasNearBottom = cv.bounds.height > 0 &&
            prevHeight - (prevOffset + cv.bounds.height) < 200

        // Detect in-place edits (same id, different content — e.g. a
        // new reaction, an edit, an unsend) and reconfigure those
        // specific cells before the diffable apply, because
        // identifier-only diffing won't notice field-level changes.
        if !coord.lastItems.isEmpty {
            let prevById = Dictionary(uniqueKeysWithValues: coord.lastItems.map { ($0.id, $0) })
            let changedIDs = items.compactMap { m -> String? in
                if let prev = prevById[m.id], prev != m { return m.id }
                return nil
            }
            if !changedIDs.isEmpty {
                var snap = coord.currentSnapshot()
                let present = changedIDs.filter { snap.itemIdentifiers.contains($0) }
                if !present.isEmpty {
                    // Update backing cache first so the cell reads the
                    // new message object on reconfigure.
                    coord.lastItems = items
                    snap.reconfigureItems(present)
                    coord.applySnapshot(snap, animated: false)
                }
            }
        }

        coord.apply(items: items, typingUsers: typingUsers, animated: false)

        // If the pinned set changed while the item list stayed the same,
        // force the affected cells to reconfigure so the pin badge
        // appears/disappears instantly.
        if coord.lastPinnedIds != pinnedIds {
            let diff = coord.lastPinnedIds.symmetricDifference(pinnedIds)
            coord.lastPinnedIds = pinnedIds
            if !diff.isEmpty {
                var snap = coord.currentSnapshot()
                let affected = diff.filter { snap.itemIdentifiers.contains($0) }
                if !affected.isEmpty {
                    snap.reconfigureItems(Array(affected))
                    coord.applySnapshot(snap, animated: false)
                }
            }
        }

        // Same trick for pulse — reconfigure the leaving and entering
        // rows so the scale animation actually runs on the bubble.
        if coord.lastPulsingId != pulsingId {
            var affected: [String] = []
            if let previous = coord.lastPulsingId { affected.append(previous) }
            if let next = pulsingId { affected.append(next) }
            coord.lastPulsingId = pulsingId
            if !affected.isEmpty {
                var snap = coord.currentSnapshot()
                let present = affected.filter { snap.itemIdentifiers.contains($0) }
                if !present.isEmpty {
                    snap.reconfigureItems(present)
                    coord.applySnapshot(snap, animated: false)
                }
            }
        }

        if coord.lastBottomInset != bottomInset {
            coord.lastBottomInset = bottomInset
            // Keyboard appeared/dismissed: schedule a scroll-to-bottom
            // AFTER the keyboard finishes animating (~0.3s) so the
            // collection view's bounds and contentSize have settled to
            // their new values before we tell it to scroll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak cv] in
                guard let cv else { return }
                coord.scrollToBottom(in: cv, animated: true)
            }
            // Also kick an immediate one in case the layout has already
            // landed (e.g., re-focusing a composer that's been showing).
            DispatchQueue.main.async { [weak cv] in
                guard let cv else { return }
                coord.scrollToBottom(in: cv, animated: false)
            }
        }

        if coord.lastLoadingMore != isLoadingMore {
            coord.lastLoadingMore = isLoadingMore
            if let header = cv.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: 0)
            ) as? UICollectionViewListCell {
                header.contentConfiguration = UIHostingConfiguration {
                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .margins(.all, 0)
                cv.collectionViewLayout.invalidateLayout()
            }
        }

        // Detect prepend (older messages loaded) vs append (new message).
        let isPrepend =
            !prevIDs.isEmpty && !newIDs.isEmpty &&
            newIDs.count > prevIDs.count &&
            newIDs.suffix(prevIDs.count) == ArraySlice(prevIDs)

        if isPrepend {
            // Preserve scroll position by compensating for newly inserted
            // height above the user's current view.
            cv.layoutIfNeeded()
            let newHeight = cv.contentSize.height
            let delta = newHeight - prevHeight
            if delta > 0 {
                cv.setContentOffset(CGPoint(x: 0, y: prevOffset + delta), animated: false)
            }
        } else if !coord.didInitialScroll && !items.isEmpty {
            // Defer to next runloop so the collection view has a chance
            // to lay out — otherwise contentSize is still zero and
            // scrollToItem becomes a no-op.
            coord.didInitialScroll = true
            DispatchQueue.main.async { [weak cv] in
                guard let cv else { return }
                cv.layoutIfNeeded()
                coord.scrollToBottom(in: cv, animated: false)
            }
        } else if newIDs != prevIDs && (wasNearBottom || !coord.didInitialScroll) {
            // Let the new cell's layout settle first, then animate the
            // scroll so the transition is smooth instead of a jump.
            DispatchQueue.main.async { [weak cv] in
                guard let cv else { return }
                cv.layoutIfNeeded()
                coord.scrollToBottom(in: cv, animated: true)
            }
            // Second pass in case estimated heights caused the first
            // layout to land short — animated: false this time so we
            // don't queue competing animations.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak cv] in
                guard let cv else { return }
                coord.scrollToBottom(in: cv, animated: false)
            }
        }

        if let id = scrollToId {
            DispatchQueue.main.async {
                coord.scrollTo(id: id, in: cv, animated: true)
                onScrollToIdConsumed()
            }
        }

        if coord.lastScrollToBottomToken != scrollToBottomToken {
            coord.lastScrollToBottomToken = scrollToBottomToken
            DispatchQueue.main.async { [weak cv] in
                guard let cv else { return }
                coord.scrollToBottom(in: cv, animated: true)
            }
        }
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ChatCollectionView
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        var lastItems: [Message] = []
        var lastTypingUsers: [String] = []
        var lastPinnedIds: Set<String> = []
        var lastPulsingId: String?
        var lastLoadingMore = false
        var lastBottomInset: CGFloat = 0
        var lastScrollToBottomToken: Int = 0
        var didInitialScroll = false
        private var loadingMore = false

        init(parent: ChatCollectionView) {
            self.parent = parent
        }

        func attach(cv: UICollectionView) {
            self.collectionView = cv
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, indexPath, id in
                guard let self else { return }
                if id == ChatTypingRowID {
                    let logins = self.lastTypingUsers
                    cell.contentConfiguration = UIHostingConfiguration {
                        TypingIndicatorRow(logins: logins)
                    }
                    .margins(.all, 0)
                    cell.backgroundConfiguration = .clear()
                    return
                }
                guard let msg = self.lastItems.first(where: { $0.id == id }) else { return }
                let idx = indexPath.item
                cell.contentConfiguration = UIHostingConfiguration {
                    self.parent.cellBuilder(msg, idx)
                }
                .margins(.all, 0)
                cell.backgroundConfiguration = .clear()
            }

            let headerKind = UICollectionView.elementKindSectionHeader
            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: headerKind
            ) { [weak self] header, _, _ in
                let loading = self?.parent.isLoadingMore == true
                header.contentConfiguration = UIHostingConfiguration {
                    if loading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .margins(.all, 0)
                header.backgroundConfiguration = .clear()
            }

            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: cv) { cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            dataSource.supplementaryViewProvider = { cv, kind, indexPath in
                cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
        }

        func reconfigureHeader() {
            collectionView?.collectionViewLayout.invalidateLayout()
        }

        func apply(items: [Message], typingUsers: [String], animated: Bool) {
            lastItems = items
            lastTypingUsers = typingUsers
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            var ids = items.map(\.id)
            if !typingUsers.isEmpty { ids.append(ChatTypingRowID) }
            snap.appendItems(ids)
            dataSource.apply(snap, animatingDifferences: animated)
        }

        func currentSnapshot() -> NSDiffableDataSourceSnapshot<Int, String> {
            dataSource.snapshot()
        }

        func applySnapshot(_ snap: NSDiffableDataSourceSnapshot<Int, String>, animated: Bool) {
            dataSource.apply(snap, animatingDifferences: animated)
        }

        func scrollTo(id: String, in cv: UICollectionView, animated: Bool) {
            guard let indexPath = dataSource.indexPath(for: id) else { return }
            cv.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
        }

        func scrollToBottom(in cv: UICollectionView, animated: Bool) {
            // Always consult the data source's current snapshot rather
            // than lastItems — a concurrent apply may have shrunk the
            // item count between scheduling and execution, and
            // scrollToItem with a stale index path crashes UIKit.
            let snap = dataSource.snapshot()
            let total = snap.numberOfItems
            guard total > 0, !snap.sectionIdentifiers.isEmpty else { return }
            let section = 0
            let sectionCount = snap.numberOfItems(inSection: snap.sectionIdentifiers[section])
            guard sectionCount > 0 else { return }
            let idx = IndexPath(item: sectionCount - 1, section: section)
            cv.scrollToItem(at: idx, at: .bottom, animated: animated)
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Backup trigger if the user lands at the top instantly.
            if indexPath.item == 0, didInitialScroll, !loadingMore {
                fireLoadMore()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Track whether the user is parked at the bottom so the
            // parent can show/hide the jump-to-latest button.
            let bottomDistance = scrollView.contentSize.height
                - (scrollView.contentOffset.y + scrollView.bounds.height)
            let atBottom = bottomDistance < 80
            if parent.isAtBottom != atBottom {
                parent.isAtBottom = atBottom
            }

            guard didInitialScroll, !loadingMore else { return }
            // Fire when the user gets within ~600pt of the top, well
            // before the actual top row enters the viewport, so older
            // messages start streaming in early.
            let threshold: CGFloat = 600
            if scrollView.contentOffset.y < threshold {
                fireLoadMore()
            }
        }

        private func fireLoadMore() {
            loadingMore = true
            parent.onTopReached()
            // Re-arm quickly — vm.loadMoreIfNeeded already guards
            // re-entrance, and we want subsequent pages to fire as soon
            // as the user keeps scrolling up through them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.loadingMore = false
            }
        }
    }
}

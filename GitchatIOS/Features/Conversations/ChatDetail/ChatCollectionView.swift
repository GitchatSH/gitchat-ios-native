import SwiftUI
import UIKit

/// UICollectionView-backed chat list. Wraps a compositional layout with
/// self-sizing UIHostingConfiguration cells and a diffable data source so
/// rows are recycled by UIKit instead of re-instantiated by SwiftUI on
/// every body invocation. This is what real chat apps (Telegram, iMessage)
/// use under the hood — much smoother than `LazyVStack` in `ScrollView`
/// for rich content with images and long lists.
struct ChatCollectionView<Cell: View>: UIViewRepresentable {
    let items: [Message]
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
        cv.contentInsetAdjustmentBehavior = .always

        context.coordinator.attach(cv: cv)
        context.coordinator.apply(items: items, animated: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        let prevIDs = coord.lastItems.map(\.id)
        let newIDs = items.map(\.id)
        let prevHeight = cv.contentSize.height
        let prevOffset = cv.contentOffset.y
        let wasNearBottom = cv.bounds.height > 0 &&
            prevHeight - (prevOffset + cv.bounds.height) < 80

        coord.apply(items: items, animated: false)

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
            DispatchQueue.main.async { [weak cv] in
                guard let cv else { return }
                coord.scrollToBottom(in: cv, animated: true)
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

        func apply(items: [Message], animated: Bool) {
            lastItems = items
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            snap.appendItems(items.map(\.id))
            dataSource.apply(snap, animatingDifferences: animated)
        }

        func scrollTo(id: String, in cv: UICollectionView, animated: Bool) {
            guard let idx = lastItems.firstIndex(where: { $0.id == id }) else { return }
            cv.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically, animated: animated)
        }

        func scrollToBottom(in cv: UICollectionView, animated: Bool) {
            guard !lastItems.isEmpty else { return }
            let idx = IndexPath(item: lastItems.count - 1, section: 0)
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

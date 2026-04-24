import SwiftUI
import UIKit
import ObjectiveC

/// Auto-hide scroll indicators on Catalyst — invisible when idle,
/// visible while actively scrolling (Telegram Desktop behavior).
///
/// Architecture: a single `ScrollIndicatorObserver` is installed per
/// `UIScrollView` via an associated object. Even though the SwiftUI
/// modifier is applied inside every row, only the first row to mount
/// installs the observer — subsequent rows reuse it. This prevents
/// the multi-observer race conditions that show up as flicker.
struct ScrollIndicatorHider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        ScrollIndicatorHiderView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? ScrollIndicatorHiderView)?.installIfNeeded()
    }
}

private final class ScrollIndicatorHiderView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    func installIfNeeded() {
        guard let sv = enclosingScrollView() else { return }
        ScrollIndicatorObserver.install(on: sv)
    }

    private func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = self
        while let v = current {
            if let scroll = v as? UIScrollView { return scroll }
            current = v.superview
        }
        return nil
    }
}

private final class ScrollIndicatorObserver {
    /// How long the indicator stays visible after the last scroll
    /// event before hiding. Short enough to feel responsive but long
    /// enough that mouse-wheel ticks (~0.4s gaps) don't flicker.
    private static let hideDelay: TimeInterval = 1.0
    private static var assocKey: UInt8 = 0

    private weak var scrollView: UIScrollView?
    private var offsetObs: NSKeyValueObservation?
    private var draggingObs: NSKeyValueObservation?
    private var deceleratingObs: NSKeyValueObservation?
    private var hideWorkItem: DispatchWorkItem?

    /// Install (or reuse) a single observer for `sv`. Idempotent — a
    /// scroll view never gets more than one observer attached, even
    /// if many rows call this.
    static func install(on sv: UIScrollView) {
        if objc_getAssociatedObject(sv, &assocKey) as? ScrollIndicatorObserver != nil { return }
        let observer = ScrollIndicatorObserver()
        objc_setAssociatedObject(sv, &assocKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        observer.start(sv)
    }

    private func start(_ sv: UIScrollView) {
        scrollView = sv
        setAlpha(0)

        offsetObs = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            self?.handle(sv)
        }
        draggingObs = sv.observe(\.isDragging, options: [.new]) { [weak self] sv, _ in
            self?.handle(sv)
        }
        deceleratingObs = sv.observe(\.isDecelerating, options: [.new]) { [weak self] sv, _ in
            self?.handle(sv)
        }
    }

    private func handle(_ sv: UIScrollView) {
        setAlpha(1)
        hideWorkItem?.cancel()

        // Hold visible while user is still touching / inertial scroll
        // is decelerating. Next event will reschedule.
        if sv.isDragging || sv.isDecelerating { return }

        let item = DispatchWorkItem { [weak self, weak sv] in
            guard let self, let sv else { return }
            if sv.isDragging || sv.isDecelerating { return }
            self.setAlpha(0)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: item)
    }

    /// Set alpha on the scroll view's indicator subviews directly.
    /// No animation — instant changes prevent mid-fade interruption
    /// that reads as flicker during sustained scrolling.
    private func setAlpha(_ alpha: CGFloat) {
        guard let sv = scrollView else { return }
        for sub in sv.subviews {
            let name = String(describing: type(of: sub))
            if name.contains("ScrollIndicator") || name.contains("Scroller") {
                sub.alpha = alpha
            }
        }
    }

    deinit {
        offsetObs?.invalidate()
        draggingObs?.invalidate()
        deceleratingObs?.invalidate()
        hideWorkItem?.cancel()
    }
}

extension View {
    /// On Catalyst, hide system scroll indicators when idle and show
    /// them only while the user is actively scrolling. Apply inside
    /// the row content (inside `List`'s row builder) so the helper
    /// can introspect up to the underlying `UICollectionView`. Safe
    /// to call from many rows — only one observer is installed per
    /// scroll view.
    @ViewBuilder
    func hideMacScrollIndicators() -> some View {
        #if targetEnvironment(macCatalyst)
        self.background(ScrollIndicatorHider().frame(width: 0, height: 0).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

import SwiftUI
import Combine
import UIKit

/// Observes the system keyboard, exposing its current visible height
/// together with the exact animation duration + curve UIKit is going
/// to use for the upcoming transition. Downstream views wrap their
/// state mutations in a `withAnimation(lastChange.swiftUIAnimation)`
/// call so the composer (and any other keyboard-aware surface) stays
/// in lock-step with the keyboard frame instead of lagging behind.
///
/// Modelled on exyte/chat's `KeyboardState` (MIT) with one material
/// addition: we capture `duration` + `curveRawValue` from the
/// notification so the SwiftUI animation matches, not an ad-hoc
/// `easeOut(0.22)` approximation.
@MainActor
final class KeyboardState: ObservableObject {
    /// Current visible keyboard height, in points. Zero when hidden.
    @Published private(set) var height: CGFloat = 0
    /// Whether the keyboard is currently showing.
    @Published private(set) var isShown: Bool = false
    /// Snapshot of the last keyboard change. Views use
    /// `.swiftUIAnimation` to animate mutations in lock-step.
    @Published private(set) var lastChange: Change = .zero

    struct Change: Equatable {
        var height: CGFloat
        var duration: TimeInterval
        /// Raw value from `UIKeyboardAnimationCurveUserInfoKey`. Keyboard
        /// curves use a private value (typically 7) that maps to the
        /// private `UIView.AnimationCurve` cases; use
        /// `animationOptions` to bridge to `UIView.AnimationOptions`.
        var curveRawValue: UInt

        static let zero = Change(height: 0, duration: 0.25, curveRawValue: 7)

        /// Bridged `UIView.AnimationOptions` for any CALayer-driven
        /// path that wants to match the keyboard exactly.
        var animationOptions: UIView.AnimationOptions {
            UIView.AnimationOptions(rawValue: curveRawValue << 16)
        }

        /// SwiftUI animation that tracks the keyboard closely.
        /// `interpolatingSpring` preserves velocity across mid-flight
        /// changes (interactive dismiss; rapid focus toggles), which
        /// `.timingCurve` does not — so the composer stays glued to
        /// the keyboard even when the user wiggles it.
        var swiftUIAnimation: Animation {
            guard duration > 0 else { return .linear(duration: 0) }
            return .interpolatingSpring(
                mass: 1.0,
                stiffness: 320,
                damping: 32,
                initialVelocity: 0
            )
        }
    }

    /// Requests the dismissal of the current first responder. Kept
    /// here rather than in a view so callers can route through the
    /// observer as an injected dependency.
    func resignFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private var bag = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default
        let willChange = center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        let willHide = center.publisher(for: UIResponder.keyboardWillHideNotification)

        willChange.merge(with: willHide)
            .compactMap { (note: Foundation.Notification) -> Change? in
                Self.change(from: note)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (change: Change) in
                guard let self else { return }
                self.lastChange = change
                withAnimation(change.swiftUIAnimation) {
                    self.height = change.height
                    self.isShown = change.height > 0
                }
            }
            .store(in: &bag)
    }

    private static func change(from note: Foundation.Notification) -> Change? {
        let info = note.userInfo ?? [:]
        let isHide = note.name == UIResponder.keyboardWillHideNotification
        let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let screenHeight = UIScreen.main.bounds.height
        let height: CGFloat = isHide ? 0 : max(0, screenHeight - frame.origin.y)
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        return Change(height: height, duration: duration, curveRawValue: curve)
    }
}

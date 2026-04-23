import SwiftUI
import Combine
import UIKit

/// Observes the keyboard height, extracting the system's animation
/// duration and curve so views can animate in lock-step with the
/// keyboard instead of with SwiftUI's default curve. That lock-step
/// is the difference between "composer snaps to keyboard" and
/// "composer lags a few frames behind".
///
/// SwiftUI's built-in keyboard avoidance sometimes leaves a trailing
/// bottom inset after dismissal, and its animation curve does not
/// match the keyboard's, so we drive it ourselves.
@MainActor
final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    @Published private(set) var lastChange: Change = .zero

    struct Change {
        var height: CGFloat
        var duration: TimeInterval
        /// Raw value from `UIKeyboardAnimationCurveUserInfoKey`. Keyboard
        /// curves use private values (often `7`) that map to the private
        /// `UIView.AnimationCurve` cases; use `animationOptions` to
        /// bridge to `UIView.AnimationOptions`.
        var curveRawValue: UInt

        static let zero = Change(height: 0, duration: 0.25, curveRawValue: 7)

        var animationOptions: UIView.AnimationOptions {
            UIView.AnimationOptions(rawValue: curveRawValue << 16)
        }

        /// SwiftUI animation tuned to track the keyboard in lock-step.
        /// `interpolatingSpring` reads the current velocity of the
        /// animatable value so mid-flight reversals (interactive
        /// dismiss; dragging the keyboard) don't break the tracking —
        /// unlike `timingCurve` which restarts from velocity=0 on every
        /// new change. stiffness 320/damping 30 is the same profile
        /// Apple uses on UIKit's bottom-sheet tracking.
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

    private var bag: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        let show = center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        let hide = center.publisher(for: UIResponder.keyboardWillHideNotification)

        show.merge(with: hide)
            .compactMap { (note: Foundation.Notification) -> Change? in KeyboardObserver.change(from: note) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (change: Change) in
                guard let self else { return }
                self.lastChange = change
                withAnimation(change.swiftUIAnimation) {
                    self.height = change.height
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

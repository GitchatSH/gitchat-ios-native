import SwiftUI
import Combine
import UIKit

/// Observes the keyboard height so views can reactively push content up
/// without relying on SwiftUI's built-in keyboard avoidance (which
/// sometimes leaves a trailing bottom inset after dismissal).
@MainActor
final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0

    private var bag: Set<AnyCancellable> = []

    init() {
        let willShow = NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .compactMap { note -> CGFloat? in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return nil }
                let screenHeight = UIScreen.main.bounds.height
                return max(0, screenHeight - frame.origin.y)
            }
        let willHide = NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }

        willShow
            .merge(with: willHide)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] h in
                withAnimation(.easeOut(duration: 0.22)) {
                    self?.height = h
                }
            }
            .store(in: &bag)
    }
}

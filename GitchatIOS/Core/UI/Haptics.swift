import UIKit

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    static func notify(_ kind: Toast.Kind) {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        switch kind {
        case .success: g.notificationOccurred(.success)
        case .warning: g.notificationOccurred(.warning)
        case .error: g.notificationOccurred(.error)
        case .info: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

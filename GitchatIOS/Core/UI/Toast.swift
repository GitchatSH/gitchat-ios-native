import SwiftUI
import UIKit

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case success, info, warning, error
        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
        var tint: Color {
            switch self {
            case .success: return .green
            case .info: return .accentColor
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String?
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ kind: Toast.Kind, _ title: String, _ subtitle: String? = nil) {
        Haptics.notify(kind)
        dismissTask?.cancel()
        let toast = Toast(kind: kind, title: title, subtitle: subtitle)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            current = toast
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self?.current = nil
                }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { current = nil }
    }
}

struct ToastHostModifier: ViewModifier {
    @StateObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = center.current {
                ToastView(toast: t)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
                    .zIndex(10_000)
            }
        }
    }
}

extension View {
    func toastHost() -> some View { modifier(ToastHostModifier()) }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(toast.kind.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.label))
                if let sub = toast.subtitle {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if #available(iOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
    }
}

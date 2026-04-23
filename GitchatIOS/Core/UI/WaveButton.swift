import SwiftUI

/// Low-friction "say hi" button. Renders idle / pending / waved, uses
/// `WaveHistory` so one tap from any surface (profile, discover people
/// row, etc.) persists for the rest of the session.
struct WaveButton: View {
    let targetLogin: String
    var style: Style = .standard

    enum Style { case standard, compact }

    @ObservedObject private var history = WaveHistory.shared

    var body: some View {
        Button { Task { await tap() } } label: {
            if history.isPending(targetLogin) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 64, height: 22)
            } else if history.alreadyWaved(targetLogin) {
                Label("Waved", systemImage: "hand.wave.fill")
            } else {
                Label("Wave", systemImage: "hand.wave")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(style == .compact ? .mini : .small)
        .disabled(history.alreadyWaved(targetLogin) || history.isPending(targetLogin))
    }

    private func tap() async {
        Haptics.impact(.light)
        history.markPending(targetLogin)
        do {
            _ = try await APIClient.shared.sendWave(to: targetLogin)
            history.markWaved(targetLogin)
            ToastCenter.shared.show(.success, "Waved at @\(targetLogin)")
        } catch {
            history.markFailed(targetLogin)
            let msg = error.localizedDescription.lowercased()
            // Don't leak "blocked" state. BE returns 409 for already-waved;
            // fold that into the quiet "already waved" UX.
            if msg.contains("already") {
                history.markWaved(targetLogin)
            } else {
                ToastCenter.shared.show(.error, "Couldn't wave", error.localizedDescription)
            }
        }
    }
}

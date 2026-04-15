import SwiftUI

/// Small "syncing up." → ".." → "..." label shown under the chat name
/// in the navigation bar while a sync is in flight. Uses a TimelineView
/// so the animation advances off the wall clock and doesn't depend on
/// any state being re-initialized on reappearance.
struct SyncingDotsLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            let dots = String(repeating: ".", count: step + 1)
            Text("syncing up\(dots)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

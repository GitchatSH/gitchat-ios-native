import SwiftUI

/// Multi-segment indicator bar for the pinned message banner.
///
/// Adapts to the number of pinned messages:
/// - 1 pin:  single solid accent bar
/// - 2-3:    N segments, active = accent, subtle = accent 20%
/// - 4+:     always 3 segments, center-biased active position
struct PinnedIndicatorBar: View {
    let totalCount: Int
    let currentIndex: Int

    private let barWidth: CGFloat = 2
    private let segmentGap: CGFloat = 2
    private let cornerRadius: CGFloat = 1

    /// How many visual segments to render (capped at 3).
    private var segmentCount: Int {
        min(totalCount, 3)
    }

    /// Which visual segment (0-based) is active.
    private var activeSegment: Int {
        if totalCount <= 3 { return currentIndex }
        if currentIndex == 0 { return 0 }
        if currentIndex == totalCount - 1 { return 2 }
        return 1
    }

    var body: some View {
        if totalCount <= 1 {
            // Single bar — no segments
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color("AccentColor"))
                .frame(width: barWidth)
        } else {
            VStack(spacing: segmentGap) {
                ForEach(0..<segmentCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(i == activeSegment
                              ? Color("AccentColor")
                              : Color("AccentColor").opacity(0.20))
                        .frame(width: barWidth)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: activeSegment)
        }
    }
}

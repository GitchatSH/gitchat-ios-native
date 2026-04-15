import SwiftUI

struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let emojis: [String] = [
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍",
        "👍","👎","👏","🙌","🙏","🤝","💪","🫶",
        "😂","🤣","😅","😊","😍","🥰","😘","😎",
        "😮","😲","😱","😭","😢","😤","😡","🤬",
        "🎉","🔥","✨","💯","⭐️","💫","⚡️","💥",
        "👀","💭","💡","🧠","📌","✅","❌","🚀",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            Text("React")
                .font(.geist(16, weight: .semibold))
                .padding(.top, 16)
                .padding(.bottom, 8)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(emojis, id: \.self) { e in
                        Button {
                            Haptics.selection()
                            onPick(e)
                        } label: {
                            Text(e).font(.system(size: 30))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

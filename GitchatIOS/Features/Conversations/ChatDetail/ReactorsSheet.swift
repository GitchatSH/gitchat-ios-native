import SwiftUI

struct ReactorsSheet: View {
    let message: Message
    let participants: [ConversationParticipant]
    let myLogin: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: String = "all"

    private struct Reactor: Hashable { let login: String; let emoji: String }

    private var allReactors: [Reactor] {
        (message.reactionRows ?? []).map { Reactor(login: $0.user_login ?? "", emoji: $0.emoji) }
    }

    private var grouped: [(String, Int)] {
        var counts: [String: Int] = [:]
        for r in allReactors { counts[r.emoji, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    private var filtered: [Reactor] {
        if selectedTab == "all" { return allReactors }
        return allReactors.filter { $0.emoji == selectedTab }
    }

    private func avatar(for login: String) -> String? {
        if let p = participants.first(where: { $0.login == login })?.avatar_url { return p }
        if !login.isEmpty { return "https://github.com/\(login).png" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("All \(allReactors.count)").tag("all")
                ForEach(grouped, id: \.0) { emoji, count in
                    Text("\(emoji) \(count)").tag(emoji)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            List(filtered, id: \.self) { r in
                NavigationLink {
                    ProfileView(login: r.login)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: avatar(for: r.login), size: 36)
                        Text(r.login.isEmpty ? "@me" : "@\(r.login)")
                            .font(.subheadline)
                        Spacer()
                        Text(r.emoji).font(.system(size: 22))
                    }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .overlay {
                if allReactors.isEmpty {
                    ContentUnavailableCompat(
                        title: "No reactions",
                        systemImage: "face.smiling",
                        description: "Tap an emoji to react."
                    )
                }
            }
        }
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
    }
}

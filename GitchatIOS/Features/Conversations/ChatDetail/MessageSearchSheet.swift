import SwiftUI

struct MessageSearchSheet: View {
    let conversation: Conversation
    @State private var query: String = ""
    @State private var results: [Message] = []
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(results) { m in
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(m.sender)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(m.content).font(.subheadline)
                Text(RelativeTime.format(m.created_at))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        #if !targetEnvironment(macCatalyst)
            .scrollContentBackground(.hidden)
            #endif
        #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
        .overlay {
            if isLoading {
                ProgressView()
            } else if results.isEmpty && !query.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    description: "Try another search."
                )
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this chat")
        .onChange(of: query) { newValue in
            Task { await runSearch(newValue) }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
    }

    private func runSearch(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        isLoading = true; defer { isLoading = false }
        do {
            results = try await APIClient.shared.searchMessagesInConversation(id: conversation.id, q: trimmed)
        } catch { results = [] }
    }
}

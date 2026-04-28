import Foundation
import Combine

@MainActor
final class DraftStore: ObservableObject {
    static let shared = DraftStore()
    static let draftChangedNotification = NSNotification.Name("gitchatDraftChanged")

    private var drafts: [String: String] = [:]
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = NotificationCenter.default
            .publisher(for: Self.draftChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let convoId = note.userInfo?["conversationId"] as? String else { return }
                self?.reload(convoId)
            }
    }

    func draft(for conversationId: String) -> String? {
        if let cached = drafts[conversationId] {
            return cached.isEmpty ? nil : cached
        }
        let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversationId)") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[conversationId] = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private func reload(_ conversationId: String) {
        let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversationId)") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = drafts[conversationId]
        drafts[conversationId] = trimmed
        if old != trimmed { objectWillChange.send() }
    }

    func loadAll(for conversationIds: [String]) {
        for id in conversationIds {
            let raw = UserDefaults.standard.string(forKey: "gitchat.draft.\(id)") ?? ""
            drafts[id] = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

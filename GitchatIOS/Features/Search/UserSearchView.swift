import SwiftUI

/// Minimal search-by-login screen used by `GuestTabView`. Mounts a
/// `ProfileView` for the typed login on submit. ProfileView already
/// handles 404/5xx and renders public profiles via the unauthenticated
/// `GET /user/:username` endpoint.
struct UserSearchView: View {
    @State private var query: String = ""
    @State private var pushedLogin: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Find a developer")
                    .font(.geist(22, weight: .bold))
                    .padding(.top, 24)
                Text("Type a GitHub username to view their profile.")
                    .font(.geist(13, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                TextField("e.g. tj", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .onSubmit { submit() }
                Button("Open profile") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .navigationTitle("Search")
            .navigationDestination(isPresented: Binding(
                get: { pushedLogin != nil },
                set: { if !$0 { pushedLogin = nil } }
            )) {
                if let login = pushedLogin {
                    ProfileView(login: login)
                }
            }
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pushedLogin = trimmed
    }
}

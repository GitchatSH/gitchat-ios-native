import SwiftUI

/// Telegram-style full-screen pinned messages view.
/// Shows pinned messages as chat bubbles with jump buttons,
/// header with count, footer with "Unpin all" + search.
struct PinnedMessagesSheet: View {
    let conversation: Conversation
    let myLogin: String?
    var onJumpToMessage: ((String) -> Void)? = nil
    var onUnpinAll: (() -> Void)? = nil

    @State private var messages: [Message] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var showUnpinConfirm = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatTheme) private var theme
    @FocusState private var searchFocused: Bool

    private var filtered: [Message] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return messages }
        return messages.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ZStack {
            ChatBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                if showSearch {
                    searchHeader
                } else {
                    header
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if messages.isEmpty {
                    Spacer()
                    ContentUnavailableCompat(
                        title: "No pinned messages",
                        systemImage: "pin",
                        description: "Long-press a message and tap Pin."
                    )
                    Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    Text("No results")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    messageList
                }

                if !showSearch {
                    footer
                }
            }
        }
        .environment(\.chatTheme, .default)
        .confirmationDialog(
            "Unpin all \(messages.count) messages?",
            isPresented: $showUnpinConfirm,
            titleVisibility: .visible
        ) {
            Button("Unpin All", role: .destructive) {
                onUnpinAll?()
                dismiss()
            }
        }
        .task {
            do {
                messages = try await APIClient.shared.pinnedMessages(
                    conversationId: conversation.id
                )
            } catch {}
            isLoading = false
        }
    }

    // MARK: - Header (normal mode)

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .modifier(GlassCircle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(messages.count) pinned message\(messages.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .modifier(GlassPill())

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Search header (replaces normal header)

    private var searchHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in chat", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .modifier(GlassPill())

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch = false
                    searchText = ""
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .modifier(GlassCircle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                searchFocused = true
            }
        }
        .transition(.opacity)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filtered) { msg in
                    pinnedMessageRow(msg)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func pinnedMessageRow(_ msg: Message) -> some View {
        let isMe = msg.sender == myLogin
        HStack(alignment: .bottom, spacing: 6) {
            ChatMessageView(
                message: msg,
                isMe: isMe,
                myLogin: myLogin,
                showHeader: true,
                showTail: true,
                isGroup: conversation.isGroup
            )

            // Jump button
            Button {
                jumpTo(msg)
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color("AccentColor"))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { jumpTo(msg) }
    }

    private func jumpTo(_ msg: Message) {
        onJumpToMessage?(msg.id)
        // Small delay so pendingJumpId is set before sheet dismisses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dismiss()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button { showUnpinConfirm = true } label: {
                Text("Unpin all messages")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(GlassPill())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

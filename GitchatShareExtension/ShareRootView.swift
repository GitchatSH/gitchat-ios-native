import SwiftUI
import UIKit

@MainActor
final class ShareViewModel: ObservableObject {
    @Published var conversations: [ShareConversation] = []
    @Published var loading = true
    @Published var authError = false
    @Published var errorMessage: String?
    @Published var selectedId: String?
    @Published var caption: String = ""
    @Published var sending = false
    @Published var sendProgress: String?

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await ShareAPI.shared.listConversations()
            self.conversations = list
        } catch ShareAPIError.notAuthenticated {
            self.authError = true
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func send(payload: SharePayload, onSent: @escaping () -> Void) {
        guard let conversationId = selectedId else { return }
        sending = true
        errorMessage = nil

        Task {
            do {
                var urls: [String] = []

                for (index, image) in payload.images.enumerated() {
                    sendProgress = "Uploading image \(index + 1)/\(payload.images.count)…"
                    guard let jpeg = image.jpegData(compressionQuality: 0.9) else { continue }
                    let att = ShareAttachment(data: jpeg, filename: "image-\(index + 1).jpg", mimeType: "image/jpeg")
                    let url = try await ShareAPI.shared.uploadAttachment(att, conversationId: conversationId)
                    urls.append(url)
                }

                for (index, file) in payload.files.enumerated() {
                    sendProgress = "Uploading file \(index + 1)/\(payload.files.count)…"
                    let att = ShareAttachment(data: file.data, filename: file.filename, mimeType: file.mime)
                    let url = try await ShareAPI.shared.uploadAttachment(att, conversationId: conversationId)
                    urls.append(url)
                }

                sendProgress = "Sending…"
                let body = composedBody(payload: payload)
                try await ShareAPI.shared.sendMessage(conversationId: conversationId, body: body, attachmentURLs: urls)
                sendProgress = "Sent"
                onSent()
            } catch {
                self.errorMessage = error.localizedDescription
                self.sending = false
                self.sendProgress = nil
            }
        }
    }

    private func composedBody(payload: SharePayload) -> String {
        var parts: [String] = []
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if let text = payload.text, !text.isEmpty,
           text.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
            parts.append(text)
        }
        if let url = payload.url { parts.append(url.absoluteString) }
        return parts.joined(separator: "\n")
    }
}

struct ShareRootView: View {
    let payload: SharePayload
    let onCancel: () -> Void
    let onSent: () -> Void
    @StateObject private var vm = ShareViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.authError {
                    signedOutView
                } else if vm.loading {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pickerForm
                }
            }
            .navigationTitle("Share to Gitchat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        vm.send(payload: payload, onSent: onSent)
                    } label: {
                        if vm.sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Send").bold()
                        }
                    }
                    .disabled(vm.selectedId == nil || vm.sending || payload.isEmpty)
                }
            }
            .task { await vm.load() }
        }
    }

    private var pickerForm: some View {
        Form {
            if !payload.images.isEmpty {
                Section("Attachments") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(payload.images.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if !payload.files.isEmpty {
                Section {
                    ForEach(Array(payload.files.enumerated()), id: \.offset) { _, file in
                        Label(file.filename, systemImage: "doc")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Files")
                }
            }
            if payload.text != nil || payload.url != nil {
                Section("Preview") {
                    if let url = payload.url {
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let text = payload.text, !text.isEmpty {
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            Section("Message") {
                TextField("Add a note (optional)", text: $vm.caption, axis: .vertical)
                    .lineLimit(1...4)
            }
            Section("Send to") {
                if vm.conversations.isEmpty {
                    Text("No conversations found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.conversations) { c in
                        Button {
                            vm.selectedId = c.id
                        } label: {
                            HStack(spacing: 12) {
                                avatar(for: c)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color(.label))
                                    if let sub = c.subtitle {
                                        Text(sub).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if vm.selectedId == c.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color("AccentColor"))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let progress = vm.sendProgress {
                Section { Text(progress).font(.caption).foregroundStyle(.secondary) }
            }
            if let msg = vm.errorMessage {
                Section { Text(msg).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var signedOutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in to Gitchat first").font(.headline)
            Text("Open the Gitchat app and sign in, then try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func avatar(for c: ShareConversation) -> some View {
        if let urlString = c.avatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Color.gray.opacity(0.2)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Circle().fill(Color.gray.opacity(0.2)).frame(width: 36, height: 36)
        }
    }
}

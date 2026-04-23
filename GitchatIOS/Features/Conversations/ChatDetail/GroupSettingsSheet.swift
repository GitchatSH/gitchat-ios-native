import SwiftUI
import PhotosUI

/// Admin-facing sheet for renaming a group and changing its avatar.
/// BE: PATCH /messages/conversations/:id/group with partial body.
struct GroupSettingsSheet: View {
    let conversation: Conversation
    var onSaved: ((_ newName: String?, _ newAvatarUrl: String?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var showPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingCropImage: UIImage?
    @State private var uploadedAvatarUrl: String?
    @State private var previewAvatarImage: UIImage?
    @State private var saving = false
    @State private var uploadingAvatar = false

    init(conversation: Conversation, onSaved: ((_ newName: String?, _ newAvatarUrl: String?) -> Void)? = nil) {
        self.conversation = conversation
        self.onSaved = onSaved
        self._name = State(initialValue: conversation.group_name ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameChanged: Bool {
        trimmedName != (conversation.group_name ?? "")
    }

    private var hasChanges: Bool {
        (nameChanged && !trimmedName.isEmpty) || uploadedAvatarUrl != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        avatarButton
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Group name") {
                    TextField("Group name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Group settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!hasChanges)
                    }
                }
            }
            .photosPicker(isPresented: $showPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        pendingCropImage = img
                    }
                }
            }
            .sheet(item: Binding<IdentifiableImage?>(
                get: { pendingCropImage.map(IdentifiableImage.init) },
                set: { if $0 == nil { pendingCropImage = nil } }
            )) { wrapper in
                ImageCropSheet(image: wrapper.image) { cropped in
                    pendingCropImage = nil
                    Task { await uploadAvatar(cropped) }
                }
            }
        }
    }

    private var avatarButton: some View {
        Button {
            showPicker = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let previewAvatarImage {
                    Image(uiImage: previewAvatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else {
                    AvatarView(url: conversation.group_avatar_url, size: 96)
                }
                if uploadingAvatar {
                    ProgressView().controlSize(.small)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                } else {
                    Image(systemName: "camera.fill")
                        .font(.footnote)
                        .padding(8)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(uploadingAvatar || saving)
    }

    private func uploadAvatar(_ image: UIImage) async {
        uploadingAvatar = true
        defer { uploadingAvatar = false }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            ToastCenter.shared.show(.error, "Couldn't encode image")
            return
        }
        do {
            let url = try await APIClient.shared.uploadAttachment(
                data: data,
                filename: "group-avatar.jpg",
                mimeType: "image/jpeg",
                conversationId: conversation.id
            )
            uploadedAvatarUrl = url
            previewAvatarImage = image
        } catch {
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let newName: String? = nameChanged ? trimmedName : nil
            try await APIClient.shared.updateGroup(
                id: conversation.id,
                name: newName,
                avatarUrl: uploadedAvatarUrl
            )
            ToastCenter.shared.show(.success, "Group updated")
            onSaved?(newName, uploadedAvatarUrl)
            dismiss()
        } catch {
            ToastCenter.shared.show(.error, "Save failed", error.localizedDescription)
        }
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

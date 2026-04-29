import SwiftUI

struct TopicCreateSheet: View {
    let parent: Conversation
    let onCreated: (Topic) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedEmoji: String = TopicEmojiPresets.default
    @State private var selectedColor: TopicColorToken = .blue
    @State private var inFlight = false
    @State private var nameError: String?
    @FocusState private var isNameFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inFlight
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Bug Reports", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onChange(of: name) { newValue in
                            if newValue.count > 50 { name = String(newValue.prefix(50)) }
                        }
                    if let err = nameError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("Topic name") }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TopicEmojiPresets.all, id: \.self) { emoji in
                                emojiButton(emoji)
                            }
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Icon") }

                Section {
                    HStack(spacing: 12) {
                        ForEach(TopicColorToken.allCases, id: \.self) { token in
                            colorDot(token)
                        }
                    }.padding(.vertical, 4)
                } header: { Text("Color") }
            }
            .navigationTitle("New Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await submit() } }
                        .disabled(!canCreate)
                }
            }
            .onAppear { isNameFocused = true }
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        let selected = emoji == selectedEmoji
        return Button { selectedEmoji = emoji } label: {
            Text(emoji).font(.title2)
                .frame(width: 44, height: 44)
                .background(selected ? Color("AccentColor").opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color("AccentColor") : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Icon \(emoji)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func colorDot(_ token: TopicColorToken) -> some View {
        let selected = token == selectedColor
        return Button { selectedColor = token } label: {
            Circle().fill(token.color)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? Color("AccentColor") : .clear, lineWidth: 3)
                    .padding(-3))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(token.rawValue.capitalized)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func submit() async {
        inFlight = true; nameError = nil
        do {
            let topic = try await APIClient.shared.createTopic(
                parentId: parent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                iconEmoji: selectedEmoji,
                colorToken: selectedColor.rawValue
            )
            onCreated(topic)
            ToastCenter.shared.show(.success, "Topic created", nil)
            dismiss()
        } catch let APIError.http(status, body) where status == 409
                                            && (body ?? "").contains("TOPIC_NAME_DUPLICATE") {
            nameError = "Name already in use"
        } catch let APIError.http(status, body) where status == 409
                                            && (body ?? "").contains("TOPIC_LIMIT_REACHED") {
            ToastCenter.shared.show(.error, "Topic limit reached",
                                     "This conversation has 100 topics already")
        } catch let APIError.http(status, body) where status == 409
                                            && (body ?? "").contains("TOPIC_USER_LIMIT_REACHED") {
            ToastCenter.shared.show(.error, "Your topic limit reached",
                                     "You can create up to 5 topics per conversation")
        } catch let APIError.http(status, _) where status == 429 {
            ToastCenter.shared.show(.error, "You're creating topics too fast",
                                     "Try again later")
        } catch let APIError.http(status, body) where status == 403 {
            NSLog("[Topic.create] 403 body=%@", body ?? "<nil>")
            ToastCenter.shared.show(.error, "Only admins can create topics here", nil)
            dismiss()
        } catch {
            NSLog("[Topic.create] error=%@", String(describing: error))
            ToastCenter.shared.show(.error, "Could not create topic", "Try again")
        }
        inFlight = false
    }
}

import SwiftUI
import PhotosUI

/// Telegram-style send-images sheet: full-bleed current-image hero at
/// top, horizontal thumbnail strip below for multi-select, then a
/// composer with caption + send button. Replaces the old 2-column grid
/// layout which felt cramped for a single image and had no obvious
/// "current selection" concept.
struct ImageSendPreview: View {
    @Binding var images: [UIImage]
    @Binding var caption: String
    @Binding var cropTarget: Int?
    @Binding var photoItems: [PhotosPickerItem]

    let onCancel: () -> Void
    let onSend: () -> Void

    @State private var selectedIndex: Int = 0

    private var safeIndex: Int {
        guard !images.isEmpty else { return 0 }
        return min(max(0, selectedIndex), images.count - 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hero
                thumbnailStrip
                composer
            }
            .background(Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !images.isEmpty {
                        Button("Edit") { cropTarget = safeIndex }
                    }
                }
            }
            .sheet(item: Binding<CropRoute?>(
                get: { cropTarget.map(CropRoute.init) },
                set: { cropTarget = $0?.index }
            )) { route in
                if route.index < images.count {
                    ImageCropSheet(image: images[route.index]) { cropped in
                        images[route.index] = cropped
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var title: String {
        let n = images.count
        return n == 1 ? "Send image" : "Send \(n) images"
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if images.isEmpty {
            Color.clear.frame(maxHeight: .infinity)
        } else {
            ZStack {
                Color.black
                Image(uiImage: images[safeIndex])
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                    .id(safeIndex)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Thumbnail strip

    @ViewBuilder
    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        thumbnailTile(image: img, index: i)
                            .id(i)
                    }
                    addMoreTile
                        .id("add-more")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: images.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(safeIndex, anchor: .center)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func thumbnailTile(image: UIImage, index: Int) -> some View {
        let isSelected = index == safeIndex
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedIndex = index }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? Color("AccentColor") : Color.clear,
                                lineWidth: 2
                            )
                    )
                Button {
                    remove(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("Remove image")
            }
        }
        .buttonStyle(.plain)
    }

    private var addMoreTile: some View {
        PhotosPicker(
            selection: $photoItems,
            maxSelectionCount: max(1, 10 - images.count),
            matching: .images
        ) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .foregroundStyle(Color(.tertiaryLabel))
                )
                .accessibilityLabel("Add more images")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Add a message…", text: $caption, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color("AccentColor"), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(images.isEmpty)
            .opacity(images.isEmpty ? 0.5 : 1)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(.systemBackground)
                .overlay(Divider(), alignment: .top)
        )
    }

    // MARK: - Actions

    private func remove(at index: Int) {
        guard index < images.count else { return }
        images.remove(at: index)
        if images.isEmpty {
            onCancel()
            return
        }
        if selectedIndex >= images.count {
            selectedIndex = images.count - 1
        }
    }
}

import SwiftUI

struct ImageViewerSheet: View {
    let urls: [String]
    let startIndex: Int
    /// When set, takes precedence over `@Environment(\.dismiss)`.
    /// Lets the view be hosted in a plain ZStack overlay (instead of
    /// a .fullScreenCover) and still have a way to close.
    let onClose: (() -> Void)?
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(urls: [String], startIndex: Int, onClose: (() -> Void)? = nil) {
        self.urls = urls
        self.startIndex = startIndex
        self.onClose = onClose
        _index = State(initialValue: startIndex)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var dismissProgress: CGFloat {
        min(1, abs(dragOffset) / 220)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(1 - dismissProgress)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    ZoomableImage(url: url).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .offset(y: dragOffset)
            .scaleEffect(1 - dismissProgress * 0.15)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.height) > 120 {
                            close()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
            .opacity(1 - dismissProgress)

            // Hardware-keyboard navigation between images. Hidden
            // buttons hold the shortcuts so they fire regardless of
            // which subview has focus on Mac Catalyst / iPad with a
            // connected keyboard. Esc closes the viewer.
            keyboardShortcuts
        }
        .statusBarHidden(true)
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        VStack(spacing: 0) {
            Button("Previous image") {
                if index > 0 {
                    withAnimation(.easeInOut(duration: 0.2)) { index -= 1 }
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next image") {
                if index < urls.count - 1 {
                    withAnimation(.easeInOut(duration: 0.2)) { index += 1 }
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close viewer") { close() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct ZoomableImage: View {
    let url: String
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Low-res cached variant (the 800px tile version) captured once
    /// on appear. Rendered as the bottom layer so the push / zoom
    /// transition always has solid content to morph into — without
    /// this, the viewer shows a transparent frame until the 2048px
    /// variant finishes downsampling, which reads as a flicker.
    @State private var lowResSnapshot: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = lowResSnapshot {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                }
                CachedAsyncImage(
                    url: URL(string: url),
                    contentMode: .fit,
                    placeholder: .transparent,
                    maxPixelSize: 2048
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            // Magnification is always active — pinch to zoom in/out.
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, min(4, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 {
                            withAnimation(.spring()) {
                                offset = .zero; lastOffset = .zero
                            }
                        }
                    }
            )
            // Pan gesture only when zoomed — otherwise horizontal
            // touches must reach the parent TabView so it can page
            // between images.
            .gesture(
                scale > 1 ?
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastOffset = offset }
                : nil
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if scale > 1 {
                        scale = 1; lastScale = 1
                        offset = .zero; lastOffset = .zero
                    } else {
                        scale = 2; lastScale = 2
                    }
                }
            }
        }
        .onAppear {
            if lowResSnapshot == nil, let u = URL(string: url) {
                // The grid tile primes the 800px key. Reuse it as
                // the starting frame so the zoom transition has
                // content immediately; the 2048px layer fades in
                // on top once it decodes.
                lowResSnapshot = ImageCache.shared.image(for: u, maxPixelSize: 800)
            }
        }
    }
}

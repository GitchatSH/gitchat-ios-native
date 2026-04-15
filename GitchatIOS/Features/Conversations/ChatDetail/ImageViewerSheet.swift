import SwiftUI

struct ImageViewerSheet: View {
    let urls: [String]
    let startIndex: Int
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(urls: [String], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
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
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            Button {
                dismiss()
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
        }
        .statusBarHidden(true)
    }
}

private struct ZoomableImage: View {
    let url: String
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            imageView
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    SimultaneousGesture(
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
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
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
    }

    private var imageView: some View {
        CachedAsyncImage(url: URL(string: url), contentMode: .fit, placeholder: .transparent)
    }
}

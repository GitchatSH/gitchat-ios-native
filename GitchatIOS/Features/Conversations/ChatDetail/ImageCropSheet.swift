import SwiftUI
import UIKit

struct CropRoute: Identifiable {
    let index: Int
    var id: Int { index }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, portrait, landscape
    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .landscape: return "16:9"
        }
    }

    /// Returns a size ratio where width / height == aspect.
    /// `nil` means no enforced aspect.
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .landscape: return 16.0 / 9.0
        }
    }
}

/// Pan + zoom cropper. The crop window is a fixed rect on screen; the
/// image moves underneath it. "Done" renders whatever's visible inside
/// the crop rect into a new UIImage at native resolution.
struct ImageCropSheet: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var aspect: CropAspect = .free
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let cropRect = self.cropRect(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in scale = max(0.5, lastScale * value) }
                                    .onEnded { _ in lastScale = scale },
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                        )

                    cropOverlay(rect: cropRect, canvas: geo.size)
                }
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Aspect", selection: $aspect) {
                        ForEach(CropAspect.allCases) { a in
                            Text(a.title).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let cropped = render() {
                            onCrop(cropped)
                        }
                        dismiss()
                    }.bold()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        scale = 1; lastScale = 1
                        offset = .zero; lastOffset = .zero
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func cropRect(in canvas: CGSize) -> CGRect {
        let padding: CGFloat = 24
        let maxW = canvas.width - padding * 2
        let maxH = canvas.height - 240
        guard let ratio = aspect.ratio else {
            return CGRect(x: padding, y: (canvas.height - maxH) / 2, width: maxW, height: maxH)
        }
        var w = maxW
        var h = w / ratio
        if h > maxH { h = maxH; w = h * ratio }
        return CGRect(
            x: (canvas.width - w) / 2,
            y: (canvas.height - h) / 2,
            width: w,
            height: h
        )
    }

    @ViewBuilder
    private func cropOverlay(rect: CGRect, canvas: CGSize) -> some View {
        // Dim everything outside the crop rect using an even-odd fill.
        Path { p in
            p.addRect(CGRect(origin: .zero, size: canvas))
            p.addRect(rect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        Rectangle()
            .strokeBorder(Color.white, lineWidth: 1)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// Renders the source image at native resolution, applying the same
    /// pan/zoom, then crops to the window. Works by laying out the image
    /// as it appears on screen in an offscreen renderer, then cropping
    /// the render to the crop rect.
    private func render() -> UIImage? {
        let screenScale = UIScreen.main.scale

        // Figure out the on-screen canvas by asking the current key
        // window — we can't see GeometryReader's size from here.
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first else {
            return nil
        }
        let canvas = window.bounds.size

        let rect = cropRect(in: canvas)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale

        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let full = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))

            // Match SwiftUI's `.scaledToFit().scaleEffect(scale).offset(offset)`.
            let aspect = image.size.width / image.size.height
            let canvasAspect = canvas.width / canvas.height
            var fit = canvas
            if aspect > canvasAspect {
                fit.height = canvas.width / aspect
            } else {
                fit.width = canvas.height * aspect
            }
            let drawW = fit.width * scale
            let drawH = fit.height * scale
            let drawX = (canvas.width - drawW) / 2 + offset.width
            let drawY = (canvas.height - drawH) / 2 + offset.height
            image.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }

        // Crop the rendered canvas to the window at device resolution.
        let cg = full.cgImage
        let scaleFactor = screenScale
        let cropPixels = CGRect(
            x: rect.origin.x * scaleFactor,
            y: rect.origin.y * scaleFactor,
            width: rect.width * scaleFactor,
            height: rect.height * scaleFactor
        )
        guard let cropped = cg?.cropping(to: cropPixels) else { return nil }
        return UIImage(cgImage: cropped, scale: screenScale, orientation: .up)
    }
}

import SwiftUI
import UIKit
import Mantis

struct CropRoute: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Photos-style cropper backed by Mantis (Swift, actively maintained).
/// Replaces the previous home-grown pan/zoom implementation that
/// users found imprecise. Mantis renders the standard rotated-grid
/// crop UI with aspect ratio presets, free-form drag handles, and a
/// rotation dial — matching the iOS Photos crop screen.
struct ImageCropSheet: UIViewControllerRepresentable {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onCrop: onCrop, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIViewController {
        var config = Mantis.Config()
        config.cropViewConfig.cropShapeType = .rect
        config.presetFixedRatioType = .canUseMultiplePresetFixedRatio()
        let cropVC = Mantis.cropViewController(image: image, config: config)
        cropVC.delegate = context.coordinator
        cropVC.modalPresentationStyle = .fullScreen
        return cropVC
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, CropViewControllerDelegate {
        let onCrop: (UIImage) -> Void
        let dismiss: () -> Void

        init(onCrop: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCrop = onCrop
            self.dismiss = dismiss
        }

        func cropViewControllerDidCrop(
            _ cropViewController: Mantis.CropViewController,
            cropped: UIImage,
            transformation: Mantis.Transformation,
            cropInfo: Mantis.CropInfo
        ) {
            onCrop(cropped)
            dismiss()
        }

        func cropViewControllerDidCancel(
            _ cropViewController: Mantis.CropViewController,
            original: UIImage
        ) {
            dismiss()
        }

        func cropViewControllerDidFailToCrop(
            _ cropViewController: Mantis.CropViewController,
            original: UIImage
        ) {
            dismiss()
        }

        func cropViewControllerDidBeginResize(_ cropViewController: Mantis.CropViewController) {}

        func cropViewControllerDidEndResize(
            _ cropViewController: Mantis.CropViewController,
            original: UIImage,
            cropInfo: Mantis.CropInfo
        ) {}
    }
}

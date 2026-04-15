import UIKit
import Photos

enum ImageDownloader {
    static func saveToPhotos(url: URL) async {
        // Fetch image (from cache when possible).
        let image: UIImage?
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = await ImageCache.shared.load(url)
        }
        guard let image else {
            await MainActor.run {
                ToastCenter.shared.show(.error, "Couldn't save", "Image failed to download.")
            }
            return
        }

        // Ask for add-only photo library permission.
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: Bool
        switch status {
        case .authorized, .limited: granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    cont.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default: granted = false
        }

        guard granted else {
            await MainActor.run {
                ToastCenter.shared.show(.warning, "Photos access denied", "Enable it in Settings.")
            }
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            await MainActor.run {
                Haptics.success()
                ToastCenter.shared.show(.success, "Saved", "Image saved to Photos.")
            }
        } catch {
            await MainActor.run {
                ToastCenter.shared.show(.error, "Save failed", error.localizedDescription)
            }
        }
    }
}

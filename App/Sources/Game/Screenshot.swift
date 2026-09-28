import Photos
import UIKit

/// The pause menu's screenshot: downsampled to 1080p at most, added to Photos with add-only access.
enum Screenshot {
    static func save(_ image: CGImage) async -> String {
        let picture = downsampled(image)
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: break
        default: return "OmniPlay may not add to Photos. Allow it in Settings → Privacy → Photos."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: picture)
            }
            return "Saved to Photos."
        } catch {
            return "The screenshot was not saved: \(error.localizedDescription)"
        }
    }

    /// The short side at most 1080 pixels; smaller pictures stay as they are.
    static func downsampled(_ image: CGImage) -> UIImage {
        let short = Double(min(image.width, image.height))
        guard short > 1080 else { return UIImage(cgImage: image) }
        let scale = 1080 / short
        let size = CGSize(width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

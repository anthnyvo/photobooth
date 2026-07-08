import UIKit

/// All pixel-level photo compositing — burning a branded overlay/frame onto
/// the final file (not just showing it in the UI) and stacking multiple
/// shots into a single strip image. Both operate on raw JPEG Data in/out so
/// callers (BoothViewModel) never need to touch UIImage/UIGraphics directly.
enum PhotoCompositor {
    /// Draws the event's overlay asset (if enabled and present) over the
    /// base photo, scaled to fill the base image's exact size, and
    /// re-encodes to JPEG. Returns the original bytes unchanged if overlay
    /// is disabled or the asset is missing — callers can always just use
    /// the result without checking config themselves.
    static func applyOverlay(to photoData: Data, config: EventConfig) -> Data {
        guard config.overlay.enabled,
              let assetName = config.overlay.assetName,
              let base = UIImage(data: photoData) else {
            return photoData
        }
        let overlayURL = EventStorage.shared.assetURL(eventId: config.eventId, filename: assetName)
        guard let overlay = UIImage(contentsOfFile: overlayURL.path) else {
            return photoData
        }

        let renderer = UIGraphicsImageRenderer(size: base.size)
        let composited = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            overlay.draw(in: CGRect(origin: .zero, size: base.size))
        }
        return composited.jpegData(compressionQuality: 0.92) ?? photoData
    }

    /// Stacks shots top-to-bottom into one vertical strip, each scaled to a
    /// common width (the narrowest shot, so nothing gets cropped) with a
    /// thin gap between frames. Returns nil only if none of the shots could
    /// be decoded — callers fall back to the first raw shot in that case.
    static func compositeStrip(_ shots: [Data]) -> Data? {
        let images = shots.compactMap { UIImage(data: $0) }
        guard !images.isEmpty else { return nil }
        guard images.count > 1 else { return images[0].jpegData(compressionQuality: 0.92) }

        let stripWidth = images.map(\.size.width).min() ?? images[0].size.width
        let gap: CGFloat = stripWidth * 0.02
        let scaledHeights = images.map { $0.size.height * (stripWidth / $0.size.width) }
        let totalHeight = scaledHeights.reduce(0, +) + gap * CGFloat(images.count - 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: stripWidth, height: totalHeight))
        let composited = renderer.image { _ in
            var y: CGFloat = 0
            for (image, height) in zip(images, scaledHeights) {
                image.draw(in: CGRect(x: 0, y: y, width: stripWidth, height: height))
                y += height + gap
            }
        }
        return composited.jpegData(compressionQuality: 0.92)
    }
}

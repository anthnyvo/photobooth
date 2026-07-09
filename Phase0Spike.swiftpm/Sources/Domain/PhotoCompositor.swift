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
              let base = UIImage(data: photoData)?.downscaled(maxWidth: 1600) else {
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
    ///
    /// Each shot is downscaled before compositing: the EOS R's JPEGs are
    /// several thousand pixels wide, and decoding + drawing 3-4 of them at
    /// native resolution into one huge canvas is what was crashing this —
    /// either an out-of-memory kill or a main-thread watchdog termination
    /// from how long the render took. A strip is printed small, so there's
    /// no quality reason to keep native resolution.
    static func compositeStrip(_ shots: [Data]) -> Data? {
        let maxShotWidth: CGFloat = 1200
        let images = shots.compactMap { UIImage(data: $0)?.downscaled(maxWidth: maxShotWidth) }
        guard !images.isEmpty else { return nil }
        guard images.count > 1 else { return images[0].jpegData(compressionQuality: 0.9) }

        let stripWidth = images.map(\.size.width).min() ?? images[0].size.width
        let gap: CGFloat = stripWidth * 0.02
        let scaledHeights = images.map { $0.size.height * (stripWidth / $0.size.width) }
        let totalHeight = scaledHeights.reduce(0, +) + gap * CGFloat(images.count - 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: stripWidth, height: totalHeight))
        let composited = renderer.image { _ in
            var y: CGFloat = 0
            for (image, height) in zip(images, scaledHeights) {
                autoreleasepool {
                    image.draw(in: CGRect(x: 0, y: y, width: stripWidth, height: height))
                }
                y += height + gap
            }
        }
        return composited.jpegData(compressionQuality: 0.9)
    }

    /// Wraps the finished photo (single shot or already-composited strip) in
    /// a classic Polaroid-style white border — thin on the top/sides,
    /// noticeably thicker along the bottom (the traditional caption strip).
    /// Applied last, after overlay/strip compositing, so every saved photo
    /// gets the same physical-print look wherever it ends up: review,
    /// share, or print.
    ///
    /// Downscales first — this runs on *every* capture now, including a
    /// plain single shot, which (unlike the strip path) was never
    /// downscaled before. Rendering a fresh canvas at the EOS R's native
    /// ~6000px width was the single-photo crash: same OOM/watchdog class as
    /// the strip crash, just hitting the one path that never got the fix.
    static func addPolaroidFrame(to photoData: Data) -> Data {
        guard let image = UIImage(data: photoData)?.downscaled(maxWidth: 1600) else { return photoData }
        let sideBorder = image.size.width * 0.045
        let topBorder = sideBorder
        let bottomBorder = image.size.width * 0.16

        let canvasSize = CGSize(
            width: image.size.width + sideBorder * 2,
            height: image.size.height + topBorder + bottomBorder
        )
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let framed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            image.draw(at: CGPoint(x: sideBorder, y: topBorder))
        }
        return framed.jpegData(compressionQuality: 0.92) ?? photoData
    }
}

private extension UIImage {
    func downscaled(maxWidth: CGFloat) -> UIImage {
        guard size.width > maxWidth else { return self }
        let scale = maxWidth / size.width
        let newSize = CGSize(width: maxWidth, height: size.height * scale)
        return autoreleasepool {
            UIGraphicsImageRenderer(size: newSize).image { _ in
                self.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
    }
}

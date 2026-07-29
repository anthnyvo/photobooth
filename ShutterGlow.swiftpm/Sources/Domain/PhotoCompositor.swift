import UIKit
import CoreImage
import CoreVideo
import Vision
import BoothStorage

/// All pixel-level photo compositing — burning a branded overlay/frame onto
/// the final file (not just showing it in the UI) and stacking multiple
/// shots into a single strip image. Both operate on raw JPEG Data in/out so
/// callers (BoothViewModel) never need to touch UIImage/UIGraphics directly.
enum PhotoCompositor {
    /// Shared Core Image context — same reasoning as PhotoFilter's: building a
    /// CIContext per capture is the expensive part.
    private static let ciContext = CIContext()

    /// Green-screen without a green screen: Vision segments the person out of
    /// the shot on-device and composites them over the event's chosen backdrop
    /// image (aspect-filled to the frame). Returns the original bytes unchanged
    /// if disabled, the backdrop is missing, or segmentation fails — callers
    /// use the result without checking. Nothing leaves the device.
    static func replaceBackground(to photoData: Data, config: EventConfig) -> Data {
        guard config.backgroundReplace.enabled,
              let assetName = config.backgroundReplace.backdropAssetName,
              let base = UIImage(data: photoData)?.downscaled(maxWidth: 1600),
              let baseCG = base.cgImage else {
            return photoData
        }
        let backdropURL = EventStorage.shared.assetURL(eventId: config.eventId, filename: assetName)
        guard let backdrop = UIImage(contentsOfFile: backdropURL.path),
              let backdropCG = backdrop.croppedToAspectFill(base.size).cgImage else {
            return photoData
        }

        let request = VNGeneratePersonSegmentationRequest()
        // .fast, not .balanced: this is the single most expensive step in the
        // whole capture pipeline, and it runs while the guest waits on the
        // flash screen. At a booth print's size the edge quality difference is
        // not worth the extra second per shot — speed wins here.
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: baseCG, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else {
            return photoData
        }

        let ciBase = CIImage(cgImage: baseCG)
        var ciMask = CIImage(cvPixelBuffer: maskBuffer)
        // The segmentation mask comes back at its own resolution; scale it to
        // cover the base image exactly before using it as the blend mask.
        let scaleX = ciBase.extent.width / ciMask.extent.width
        let scaleY = ciBase.extent.height / ciMask.extent.height
        ciMask = ciMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let ciBackdrop = CIImage(cgImage: backdropCG)

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return photoData }
        blend.setValue(ciBase, forKey: kCIInputImageKey)              // person (kept where mask is white)
        blend.setValue(ciBackdrop, forKey: kCIInputBackgroundImageKey) // new background
        blend.setValue(ciMask, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage,
              let rendered = ciContext.createCGImage(output, from: ciBase.extent) else {
            return photoData
        }
        return UIImage(cgImage: rendered).jpegData(compressionQuality: 0.92) ?? photoData
    }

    /// Composites one guest-chosen sticker overlay (a transparent PNG in the
    /// event's assets/) full-frame onto the photo — same draw approach as
    /// applyOverlay, but for a per-guest pick from the sticker set rather than
    /// the single fixed event overlay. No-op if disabled or asset missing.
    static func applySticker(_ assetName: String?, to photoData: Data, config: EventConfig) -> Data {
        guard config.stickers.enabled,
              let assetName,
              let base = UIImage(data: photoData)?.downscaled(maxWidth: 1600) else {
            return photoData
        }
        let url = EventStorage.shared.assetURL(eventId: config.eventId, filename: assetName)
        guard let sticker = UIImage(contentsOfFile: url.path) else { return photoData }

        let renderer = UIGraphicsImageRenderer(size: base.size, format: .pixelExact)
        let composited = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            sticker.draw(in: CGRect(origin: .zero, size: base.size))
        }
        return composited.jpegData(compressionQuality: 0.92) ?? photoData
    }

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

        let renderer = UIGraphicsImageRenderer(size: base.size, format: .pixelExact)
        let composited = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            overlay.draw(in: CGRect(origin: .zero, size: base.size))
        }
        return composited.jpegData(compressionQuality: 0.92) ?? photoData
    }

    /// Combines shots into one image per `layout`. Returns nil only if none
    /// of the shots could be decoded — callers fall back to the first raw
    /// shot in that case.
    ///
    /// Each shot is downscaled before compositing: the EOS R's JPEGs are
    /// several thousand pixels wide, and decoding + drawing 3-4 of them at
    /// native resolution into one huge canvas is what was crashing this —
    /// either an out-of-memory kill or a main-thread watchdog termination
    /// from how long the render took. A strip is printed small, so there's
    /// no quality reason to keep native resolution.
    static func compositeStrip(_ shots: [Data], layout: EventConfig.StripOptions.Layout = .vertical) -> Data? {
        let maxShotWidth: CGFloat = 1200
        let images = shots.compactMap { UIImage(data: $0)?.downscaled(maxWidth: maxShotWidth) }
        guard !images.isEmpty else { return nil }
        guard images.count > 1 else { return images[0].jpegData(compressionQuality: 0.9) }

        switch layout {
        case .vertical:
            return compositeVertical(images)
        case .horizontal:
            return compositeHorizontal(images)
        case .grid:
            return compositeGrid(images)
        }
    }

    /// Stacks shots top-to-bottom, each scaled to a common width (the
    /// narrowest shot, so nothing gets cropped), separated by white
    /// gutters — the classic print-stock look, not black seams (an
    /// unfilled renderer background encodes to black in JPEG, which is
    /// exactly how the gaps used to come out).
    private static func compositeVertical(_ images: [UIImage]) -> Data? {
        let width = images.map(\.size.width).min() ?? images[0].size.width
        let gap: CGFloat = width * 0.05
        let scaledHeights = images.map { $0.size.height * (width / $0.size.width) }
        let totalHeight = scaledHeights.reduce(0, +) + gap * CGFloat(images.count - 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight), format: .pixelExact)
        let composited = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: totalHeight)))
            var y: CGFloat = 0
            for (image, height) in zip(images, scaledHeights) {
                autoreleasepool {
                    image.draw(in: CGRect(x: 0, y: y, width: width, height: height))
                }
                y += height + gap
            }
        }
        return composited.jpegData(compressionQuality: 0.9)
    }

    /// Shots side by side, each scaled to a common height (the shortest
    /// shot) with white gutters between them — a "duo" pair or a wide group
    /// shot, mirror of the vertical strip's math on the other axis.
    private static func compositeHorizontal(_ images: [UIImage]) -> Data? {
        let height = images.map(\.size.height).min() ?? images[0].size.height
        let gap: CGFloat = height * 0.05
        let scaledWidths = images.map { $0.size.width * (height / $0.size.height) }
        let totalWidth = scaledWidths.reduce(0, +) + gap * CGFloat(images.count - 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: height), format: .pixelExact)
        let composited = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: height)))
            var x: CGFloat = 0
            for (image, width) in zip(images, scaledWidths) {
                autoreleasepool {
                    image.draw(in: CGRect(x: x, y: 0, width: width, height: height))
                }
                x += width + gap
            }
        }
        return composited.jpegData(compressionQuality: 0.9)
    }

    /// Shots arranged in a roughly square grid (ceil(sqrt(n)) columns),
    /// each cropped to a common cell aspect ratio, separated by white
    /// gutters so the grid reads as one printed sheet.
    private static func compositeGrid(_ images: [UIImage]) -> Data? {
        let columns = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cellWidth: CGFloat = 1000
        let cellHeight = cellWidth * (images[0].size.height / images[0].size.width)
        let gap: CGFloat = cellWidth * 0.05

        let canvasSize = CGSize(
            width: cellWidth * CGFloat(columns) + gap * CGFloat(columns - 1),
            height: cellHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
        )
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: .pixelExact)
        let composited = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            for (index, image) in images.enumerated() {
                let col = index % columns
                let row = index / columns
                let cellRect = CGRect(
                    x: CGFloat(col) * (cellWidth + gap),
                    y: CGFloat(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                )
                autoreleasepool {
                    image.croppedToAspectFill(cellRect.size).draw(in: cellRect)
                }
            }
        }
        return composited.jpegData(compressionQuality: 0.9)
    }

    /// Crops one photo to a centered square. Callers apply this per SHOT,
    /// before strip compositing — cropping an already-composited strip
    /// would throw away every frame outside the centered square (a 4-shot
    /// vertical strip squared down to its middle ~2 frames).
    static func applySquareCrop(to photoData: Data) -> Data {
        guard let image = UIImage(data: photoData) else { return photoData }
        let side = min(image.size.width, image.size.height)
        let cropped = image.croppedToAspectFill(CGSize(width: side, height: side))
        return cropped.jpegData(compressionQuality: 0.92) ?? photoData
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
        // Matched to the strips' internal white gutters (5% of width) so
        // outer border and gutters read as one continuous print stock, with
        // the classic oversized chin along the bottom.
        let sideBorder = image.size.width * 0.05
        let topBorder = sideBorder
        let bottomBorder = image.size.width * 0.18

        let canvasSize = CGSize(
            width: image.size.width + sideBorder * 2,
            height: image.size.height + topBorder + bottomBorder
        )
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: .pixelExact)
        let framed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            image.draw(at: CGPoint(x: sideBorder, y: topBorder))
        }
        return framed.jpegData(compressionQuality: 0.92) ?? photoData
    }
}

// Internal (not private): FacePropRenderer downscales with the same helper
// before face detection for the same OOM-avoidance reason.
extension UIImage {
    func downscaled(maxWidth: CGFloat) -> UIImage {
        guard size.width > maxWidth else { return self }
        let scale = maxWidth / size.width
        let newSize = CGSize(width: maxWidth, height: size.height * scale)
        return autoreleasepool {
            UIGraphicsImageRenderer(size: newSize, format: .pixelExact).image { _ in
                self.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
    }

    /// Scales to fill `targetSize` (like `.scaledToFill()`) then crops the
    /// centered overflow — used for the grid layout's cells and the square
    /// crop, so content fills its target shape without stretching.
    func croppedToAspectFill(_ targetSize: CGSize) -> UIImage {
        let scale = max(targetSize.width / size.width, targetSize.height / size.height)
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaledSize.width) / 2, y: (targetSize.height - scaledSize.height) / 2)
        return autoreleasepool {
            UIGraphicsImageRenderer(size: targetSize, format: .pixelExact).image { _ in
                self.draw(in: CGRect(origin: origin, size: scaledSize))
            }
        }
    }
}

extension UIGraphicsImageRendererFormat {
    /// Scale-1 format for print-pipeline rendering. The default format uses
    /// the device's display scale, so every canvas in this file was quietly
    /// rendering at 2x its stated size on retina iPads — 4x the memory and
    /// draw time for print output where the stated size is already plenty.
    static var pixelExact: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return format
    }
}

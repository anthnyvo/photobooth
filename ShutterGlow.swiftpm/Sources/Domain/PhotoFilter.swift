import UIKit
import CoreImage

/// Guest-selectable looks applied to the final photo — picked at the attract
/// screen, burned into the saved file (same principle as the overlay and
/// Polaroid frame: what you share/print is what you saw).
public enum PhotoFilter: String, CaseIterable, Sendable, Identifiable {
    case none
    case retro
    case blackAndWhite
    case sepia
    case vivid
    case faded
    /// Beauty pass — skin smoothing + brighten + gentle warmth. Only offered
    /// when the event enables it (config.glam); see `glamCases(enabled:)`.
    case glam

    public var id: String { rawValue }

    /// The filter chips to offer at the attract screen. `glam` is gated behind
    /// the per-event toggle, so it's only in the list when enabled.
    public static func offered(glamEnabled: Bool) -> [PhotoFilter] {
        allCases.filter { $0 != .glam || glamEnabled }
    }

    var displayName: String {
        switch self {
        case .none: "Original"
        case .retro: "Retro"
        case .blackAndWhite: "B&W"
        case .sepia: "Sepia"
        case .vivid: "Vivid"
        case .faded: "Faded"
        case .glam: "Glam"
        }
    }

    /// Core Image filter backing each look — all stock CIPhotoEffect*
    /// filters (plus CISepiaTone), so no custom kernels to maintain. `glam`
    /// is a multi-filter chain instead, handled in `apply`.
    private var ciFilterName: String? {
        switch self {
        case .none, .glam: nil
        case .retro: "CIPhotoEffectInstant"
        case .blackAndWhite: "CIPhotoEffectNoir"
        case .sepia: "CISepiaTone"
        case .vivid: "CIPhotoEffectChrome"
        case .faded: "CIPhotoEffectFade"
        }
    }

    /// Shared context — creating a CIContext per capture is the expensive
    /// part of Core Image; one static instance serves every render.
    private static let context = CIContext()

    /// Applies the look and re-encodes to JPEG. Returns the original bytes
    /// unchanged for `.none` or on any decode/filter failure — callers can
    /// always use the result without checking.
    func apply(to photoData: Data) -> Data {
        guard let uiImage = UIImage(data: photoData), let cgImage = uiImage.cgImage else {
            return photoData
        }
        if self == .glam {
            return Self.applyGlam(to: cgImage) ?? photoData
        }
        guard let filterName = ciFilterName, let filter = CIFilter(name: filterName) else {
            return photoData
        }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        if self == .sepia {
            filter.setValue(0.8, forKey: kCIInputIntensityKey)
        }
        guard let output = filter.outputImage,
              let rendered = Self.context.createCGImage(output, from: output.extent) else {
            return photoData
        }
        return UIImage(cgImage: rendered).jpegData(compressionQuality: 0.92) ?? photoData
    }

    /// Glam beauty pass, chained on stock CIFilters (no custom kernels):
    /// gentle noise reduction to soften skin texture without going plastic,
    /// a small shadow lift + exposure bump to brighten, and a touch of
    /// vibrance/warmth. Deliberately subtle — a strong smooth reads as fake.
    private static func applyGlam(to cgImage: CGImage) -> Data? {
        var image = CIImage(cgImage: cgImage)

        if let nr = CIFilter(name: "CINoiseReduction") {
            nr.setValue(image, forKey: kCIInputImageKey)
            nr.setValue(0.03, forKey: "inputNoiseLevel")
            nr.setValue(0.6, forKey: "inputSharpness")
            image = nr.outputImage ?? image
        }
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(image, forKey: kCIInputImageKey)
            hs.setValue(0.35, forKey: "inputShadowAmount")
            hs.setValue(1.0, forKey: "inputHighlightAmount")
            image = hs.outputImage ?? image
        }
        if let exp = CIFilter(name: "CIExposureAdjust") {
            exp.setValue(image, forKey: kCIInputImageKey)
            exp.setValue(0.25, forKey: kCIInputEVKey)
            image = exp.outputImage ?? image
        }
        if let vib = CIFilter(name: "CIVibrance") {
            vib.setValue(image, forKey: kCIInputImageKey)
            vib.setValue(0.2, forKey: "inputAmount")
            image = vib.outputImage ?? image
        }
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(image, forKey: kCIInputImageKey)
            // Nudge slightly warm (neutral is 6500).
            temp.setValue(CIVector(x: 6800, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            image = temp.outputImage ?? image
        }

        // Clamp to the original extent — some filters (noise reduction) can
        // shift/expand the extent, and createCGImage over an infinite extent
        // fails; crop back to the source rect.
        let rect = CIImage(cgImage: cgImage).extent
        guard let rendered = context.createCGImage(image, from: rect) else { return nil }
        return UIImage(cgImage: rendered).jpegData(compressionQuality: 0.92)
    }
}

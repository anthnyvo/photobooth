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

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Original"
        case .retro: "Retro"
        case .blackAndWhite: "B&W"
        case .sepia: "Sepia"
        case .vivid: "Vivid"
        case .faded: "Faded"
        }
    }

    /// Core Image filter backing each look — all stock CIPhotoEffect*
    /// filters (plus CISepiaTone), so no custom kernels to maintain.
    private var ciFilterName: String? {
        switch self {
        case .none: nil
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
        guard let filterName = ciFilterName,
              let uiImage = UIImage(data: photoData),
              let cgImage = uiImage.cgImage,
              let filter = CIFilter(name: filterName) else {
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
}

import SwiftUI

/// GPU-composited approximation of each PhotoFilter for the live view —
/// SwiftUI saturation/contrast/tint modifiers cost nothing per frame,
/// unlike running Core Image over the live stream. The saved file still
/// goes through the real CIFilter, so the preview is a close match, not
/// the exact pixels.
extension PhotoFilter {
    var previewSaturation: Double {
        switch self {
        case .blackAndWhite: 0
        case .sepia: 0.25
        case .vivid: 1.7
        case .faded: 0.6
        default: 1
        }
    }

    var previewContrast: Double {
        switch self {
        case .vivid: 1.15
        case .faded: 0.85
        default: 1
        }
    }

    var previewTint: Color {
        switch self {
        case .retro: Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.22)
        case .sepia: Color(red: 0.62, green: 0.44, blue: 0.22).opacity(0.35)
        case .faded: Color.white.opacity(0.18)
        default: Color.clear
        }
    }
}

extension View {
    /// Applies the live-preview look for the guest's current filter pick.
    func liveFilterEffect(_ filter: PhotoFilter) -> some View {
        self
            .saturation(filter.previewSaturation)
            .contrast(filter.previewContrast)
            .overlay(filter.previewTint.ignoresSafeArea().allowsHitTesting(false))
    }
}

import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Animated capture styles — recorded from the live-view stream rather than
/// full-resolution stills (a real capture is a ~4s round trip per frame, so
/// bursting it is impossible; live view is already a steady stream of JPEGs,
/// which is the same trade every commercial booth makes for boomerangs).
public enum AnimatedStyle: String, CaseIterable, Sendable, Identifiable {
    case gif
    case boomerang

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gif: "GIF"
        case .boomerang: "Boomerang"
        }
    }

    var systemImage: String {
        switch self {
        case .gif: "film"
        case .boomerang: "arrow.left.arrow.right"
        }
    }
}

enum AnimatedCapture {
    /// Encodes live-view JPEG frames into a looping GIF. Boomerang appends
    /// the reversed frames (minus the endpoints, so the turnaround doesn't
    /// stutter) for the back-and-forth loop. The guest's filter pick is
    /// applied per frame — overlay/Polaroid are deliberately not: those are
    /// static-print concepts and would need per-frame compositing for no
    /// real payoff on a phone-screen GIF.
    static func encodeGIF(frames: [Data], style: AnimatedStyle, filter: PhotoFilter) -> Data? {
        guard !frames.isEmpty else { return nil }

        var sequence = frames
        if style == .boomerang, frames.count > 2 {
            sequence += frames.dropFirst().dropLast().reversed()
        }

        let images: [CGImage] = sequence.compactMap { frameData in
            autoreleasepool {
                UIImage(data: filter.apply(to: frameData))?.cgImage
            }
        }
        guard !images.isEmpty else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, images.count, nil
        ) else { return nil }

        let gifProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.07]
        ] as CFDictionary
        for image in images {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

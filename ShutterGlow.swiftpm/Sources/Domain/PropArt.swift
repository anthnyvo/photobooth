import UIKit

/// Where a prop's artwork sits on a face, and how big it is.
///
/// Everything is expressed in **eye distances** rather than pixels, because
/// that is the one measurement that scales correctly with how far a guest is
/// standing from the camera. A prop authored against this describes itself
/// once and lands correctly on a child at the front of the booth and an adult
/// at the back.
///
/// The frame of reference is the same face-local space the drawn props use:
/// origin at the eye centre, eyes on the x axis, +y toward the chin, already
/// rotated by head roll.
struct PropPlacement: Sendable {
    enum Anchor: Sendable {
        /// Midpoint between the eyes.
        case eyeCenter
        /// The mouth landmark, or a sensible fallback when it is missing.
        case mouth
        /// Top of the detection box, where hats and ears belong.
        case headTop
    }

    let anchor: Anchor
    /// Art width as a multiple of eye distance. A pair of sunglasses is
    /// roughly 2.2 eye distances wide; a crown is wider than the head.
    let widthInEyeDistances: CGFloat
    /// Offset from the anchor, also in eye distances. +y is toward the chin.
    let offset: CGVector
    /// Which point *in the artwork* lands on the anchor, in unit coordinates
    /// where (0.5, 0.5) is the middle of the image and (0.5, 1) is the bottom
    /// centre. Ears and hats want their bottom edge on the head top, so they
    /// use (0.5, 1); a mustache wants its centre on the offset point.
    let pivot: CGPoint

    init(
        anchor: Anchor,
        widthInEyeDistances: CGFloat,
        offset: CGVector = .zero,
        pivot: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        self.anchor = anchor
        self.widthInEyeDistances = widthInEyeDistances
        self.offset = offset
        self.pivot = pivot
    }
}

/// Bundled artwork for the face props, and the placement each piece expects.
///
/// The props ship as hand-drawn CoreGraphics paths today. Those are cheap to
/// change and cost nothing to bundle, but they are flat fills: no texture, no
/// painted shading, no material. That is the ceiling on how good they can
/// look, and it is independent of how well the face is tracked.
///
/// This is the drop-in point for real art. Put a PNG named `prop-<case>` in
/// the asset catalog (`prop-crown`, `prop-dogEars`, ...) and the renderer uses
/// it instead of drawing, at the placement declared below. Remove it and the
/// drawn path comes back. Nothing else has to change, and the two can coexist
/// while art is produced one prop at a time.
///
/// Art notes for whoever draws these:
/// - Transparent PNG, square-ish canvas, art bled to the edges it should
///   touch. The pivot below decides which edge lands on the face.
/// - Author at roughly 3x the on-screen size. Props are burned into the saved
///   file at up to 2000px wide, and that file gets printed.
/// - Bake soft shading and occlusion INTO the art. The renderer adds a contact
///   shadow underneath but does nothing else, on purpose: shading that follows
///   the artwork always beats shading a renderer guesses at.
enum PropArt {
    /// Cached so a live scan at roughly 11 frames a second is not hitting the
    /// asset catalog every pass.
    ///
    /// NSCache is documented as thread-safe, which matters because the live
    /// loop calls this from a detached task while a capture may be rendering
    /// on another. Misses are cached too, in a second cache holding a
    /// sentinel: without that, every frame pays a failed catalog lookup for
    /// every prop that has no art yet, which today is all of them.
    private static let hits = NSCache<NSString, UIImage>()
    private static let misses = NSCache<NSString, NSNull>()

    /// Artwork for a prop, or nil when none is bundled.
    static func texture(for prop: PhotoProp) -> UIImage? {
        let name = "prop-\(prop.rawValue)" as NSString

        if misses.object(forKey: name) != nil { return nil }
        if let hit = hits.object(forKey: name) { return hit }

        // Bundle.module, not .main: this is an SPM resource processed out of
        // Sources/Assets.xcassets, and .main does not see it.
        guard let image = UIImage(named: name as String, in: .module, compatibleWith: nil) else {
            misses.setObject(NSNull(), forKey: name)
            return nil
        }
        hits.setObject(image, forKey: name)
        return image
    }

    /// Where each prop's art belongs. Kept beside the art contract rather than
    /// in the renderer so that adding a prop is one entry here plus one PNG.
    ///
    /// The numbers mirror what the drawn versions already do, so a texture
    /// dropped in lands where the drawn shape used to rather than jumping.
    static func placement(for prop: PhotoProp) -> PropPlacement {
        switch prop {
        case .none:
            return PropPlacement(anchor: .eyeCenter, widthInEyeDistances: 1)
        case .sunglasses:
            return PropPlacement(anchor: .eyeCenter, widthInEyeDistances: 2.4)
        case .mustache:
            return PropPlacement(
                anchor: .mouth,
                widthInEyeDistances: 1.6,
                offset: CGVector(dx: 0, dy: -0.28)
            )
        case .dogEars:
            return PropPlacement(
                anchor: .headTop,
                widthInEyeDistances: 2.6,
                offset: CGVector(dx: 0, dy: 0.25),
                pivot: CGPoint(x: 0.5, y: 1)
            )
        case .crown:
            return PropPlacement(
                anchor: .headTop,
                widthInEyeDistances: 2.3,
                pivot: CGPoint(x: 0.5, y: 1)
            )
        case .hearts:
            return PropPlacement(anchor: .eyeCenter, widthInEyeDistances: 3.4)
        case .flowerCrown:
            return PropPlacement(
                anchor: .headTop,
                widthInEyeDistances: 2.4,
                offset: CGVector(dx: 0, dy: 0.15),
                pivot: CGPoint(x: 0.5, y: 1)
            )
        case .bunnyEars:
            return PropPlacement(
                anchor: .headTop,
                widthInEyeDistances: 1.9,
                pivot: CGPoint(x: 0.5, y: 1)
            )
        case .catWhiskers:
            return PropPlacement(anchor: .eyeCenter, widthInEyeDistances: 3.0)
        case .devilHorns:
            return PropPlacement(
                anchor: .headTop,
                widthInEyeDistances: 2.0,
                pivot: CGPoint(x: 0.5, y: 1)
            )
        case .rainbow:
            return PropPlacement(
                anchor: .mouth,
                widthInEyeDistances: 2.8,
                pivot: CGPoint(x: 0.5, y: 0.5)
            )
        }
    }
}

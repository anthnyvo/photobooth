import UIKit
import CoreImage

/// Guest-selectable AR-style props, anchored to detected faces and burned
/// into the saved file (same what-you-see-is-what-you-share principle as
/// filters/overlay). Detection is Core Image's on-device face detector —
/// nothing leaves the iPad, keeping the local-first story intact even for
/// "AI" features. Props are drawn as vector shapes (no bundled art), so
/// they scale cleanly to any face size the EOS delivers.
public enum PhotoProp: String, CaseIterable, Sendable, Identifiable {
    case none
    case sunglasses
    case mustache
    case dogEars
    case crown
    case hearts

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "No Prop"
        case .sunglasses: "Shades"
        case .mustache: "Mustache"
        case .dogEars: "Dog Ears"
        case .crown: "Crown"
        case .hearts: "Hearts"
        }
    }
}

/// One face in image coordinates (UIKit orientation, origin top-left) —
/// CIDetector reports in Core Image space (origin bottom-left), converted
/// at detection time so every renderer below can think in draw coords.
struct DetectedFace {
    let bounds: CGRect
    let leftEye: CGPoint?
    let rightEye: CGPoint?
    let mouth: CGPoint?
    let hasSmile: Bool

    /// Midpoint between the eyes — the anchor most props hang off.
    var eyeCenter: CGPoint {
        guard let leftEye, let rightEye else {
            return CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.4)
        }
        return CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    }

    /// Eye-to-eye distance, the natural scale unit for face-relative
    /// drawing; falls back to a fraction of the box for profile-ish
    /// detections where an eye is missing.
    var eyeDistance: CGFloat {
        guard let leftEye, let rightEye else { return bounds.width * 0.42 }
        return hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
    }
}

enum FaceVision {
    /// High-accuracy detector for stills (capture pipeline) and a low one
    /// for live-view polling — CIDetector construction is the expensive
    /// part, so both are static singletons.
    private static let stillDetector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    private static let liveDetector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyLow]
    )

    enum Accuracy {
        case still, live
    }

    /// Faces in UIKit coordinates (origin top-left). `imageHeight` is
    /// needed for the Core Image -> UIKit vertical flip.
    static func detectFaces(in cgImage: CGImage, accuracy: Accuracy) -> [DetectedFace] {
        let detector = accuracy == .still ? stillDetector : liveDetector
        guard let detector else { return [] }
        let height = CGFloat(cgImage.height)
        let features = detector.features(
            in: CIImage(cgImage: cgImage),
            options: [CIDetectorSmile: true]
        )
        return features.compactMap { feature in
            guard let face = feature as? CIFaceFeature else { return nil }
            let flippedBounds = CGRect(
                x: face.bounds.origin.x,
                y: height - face.bounds.origin.y - face.bounds.height,
                width: face.bounds.width,
                height: face.bounds.height
            )
            func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
            return DetectedFace(
                bounds: flippedBounds,
                leftEye: face.hasLeftEyePosition ? flip(face.leftEyePosition) : nil,
                rightEye: face.hasRightEyePosition ? flip(face.rightEyePosition) : nil,
                mouth: face.hasMouthPosition ? flip(face.mouthPosition) : nil,
                hasSmile: face.hasSmile
            )
        }
    }
}

enum FacePropRenderer {
    /// Draws the prop onto every detected face and re-encodes. Returns the
    /// original bytes unchanged for `.none`, when no face is found, or on
    /// any decode failure — safe to call unconditionally in the pipeline.
    static func apply(_ prop: PhotoProp, to photoData: Data, accuracy: FaceVision.Accuracy = .still) -> Data {
        guard prop != .none, var image = UIImage(data: photoData) else { return photoData }

        // Native EOS JPEGs are ~6000px — detection plus vector drawing at
        // that size is wasted work when the compositor downscales later
        // anyway (and full-res drawing was the original single-photo OOM
        // crash pattern).
        image = image.downscaled(maxWidth: 2000)
        guard let cgImage = image.cgImage else { return photoData }

        // Everything below works in PIXEL space (cgImage dimensions), not
        // UIImage points. downscaled() renders at device scale, so its
        // 2000-"point" result is 4000+ px on a 2x iPad — detection reports
        // pixel coordinates, and drawing on a point-sized canvas put every
        // prop at 2x its position, i.e. off the image entirely (the
        // "selected a prop but nothing showed up" bug).
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)

        var faces = FaceVision.detectFaces(in: cgImage, accuracy: accuracy)
        if faces.isEmpty && accuracy == .still {
            // High-accuracy detector can miss tilted/partial faces the fast
            // one still catches — a wrong-ish prop beats a silently missing
            // one at a photobooth.
            faces = FaceVision.detectFaces(in: cgImage, accuracy: .live)
        }
        guard !faces.isEmpty else { return photoData }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
            let cg = context.cgContext
            for face in faces {
                draw(prop, on: face, in: cg)
            }
        }
        return rendered.jpegData(compressionQuality: 0.92) ?? photoData
    }

    /// Props-only render on a transparent canvas, sized to the frame's
    /// pixels — the live-view AR preview. Displayed as a second
    /// `.scaledToFill()` layer over the live feed: same pixel aspect as the
    /// frame it was scanned from, so SwiftUI applies the identical
    /// fill/crop transform and the two layers line up without any manual
    /// coordinate mapping. Fast detector: this runs a few times a second.
    static func overlayImage(_ prop: PhotoProp, matching frameData: Data) -> UIImage? {
        guard prop != .none,
              let image = UIImage(data: frameData),
              let cgImage = image.cgImage else { return nil }

        let faces = FaceVision.detectFaces(in: cgImage, accuracy: .live)
        guard !faces.isEmpty else { return nil }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let cg = context.cgContext
            for face in faces {
                draw(prop, on: face, in: cg)
            }
        }
    }

    private static func draw(_ prop: PhotoProp, on face: DetectedFace, in cg: CGContext) {
        switch prop {
        case .none: break
        case .sunglasses: drawSunglasses(face, cg)
        case .mustache: drawMustache(face, cg)
        case .dogEars: drawDogEars(face, cg)
        case .crown: drawCrown(face, cg)
        case .hearts: drawHearts(face, cg)
        }
    }

    // MARK: - Individual props (all sized off eyeDistance so they track
    // face scale, drawn in UIKit coords: +y is down)

    private static func drawSunglasses(_ face: DetectedFace, _ cg: CGContext) {
        let d = face.eyeDistance
        let center = face.eyeCenter
        let lensRadius = d * 0.34
        let left = face.leftEye ?? CGPoint(x: center.x - d / 2, y: center.y)
        let right = face.rightEye ?? CGPoint(x: center.x + d / 2, y: center.y)

        cg.setFillColor(UIColor.black.withAlphaComponent(0.88).cgColor)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(d * 0.06)

        for eye in [left, right] {
            cg.fillEllipse(in: CGRect(
                x: eye.x - lensRadius, y: eye.y - lensRadius * 0.9,
                width: lensRadius * 2, height: lensRadius * 1.8
            ))
        }
        // bridge
        cg.move(to: CGPoint(x: left.x + lensRadius, y: left.y - lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: right.x - lensRadius, y: right.y - lensRadius * 0.2))
        cg.strokePath()
        // temples out toward the ears
        cg.move(to: CGPoint(x: left.x - lensRadius, y: left.y - lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: left.x - lensRadius - d * 0.35, y: left.y - lensRadius * 0.45))
        cg.move(to: CGPoint(x: right.x + lensRadius, y: right.y - lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: right.x + lensRadius + d * 0.35, y: right.y - lensRadius * 0.45))
        cg.strokePath()
    }

    private static func drawMustache(_ face: DetectedFace, _ cg: CGContext) {
        let d = face.eyeDistance
        guard let mouth = face.mouth else { return }
        let center = CGPoint(x: mouth.x, y: mouth.y - d * 0.28)
        let lobeWidth = d * 0.72
        let lobeHeight = d * 0.30

        let path = UIBezierPath()
        // two mirrored lobes curling up at the ends
        for side: CGFloat in [-1, 1] {
            path.move(to: center)
            path.addCurve(
                to: CGPoint(x: center.x + side * lobeWidth, y: center.y - lobeHeight * 0.45),
                controlPoint1: CGPoint(x: center.x + side * lobeWidth * 0.35, y: center.y + lobeHeight * 0.75),
                controlPoint2: CGPoint(x: center.x + side * lobeWidth * 0.95, y: center.y + lobeHeight * 0.55)
            )
            path.addCurve(
                to: center,
                controlPoint1: CGPoint(x: center.x + side * lobeWidth * 0.7, y: center.y - lobeHeight * 0.9),
                controlPoint2: CGPoint(x: center.x + side * lobeWidth * 0.25, y: center.y - lobeHeight * 0.35)
            )
        }
        cg.setFillColor(UIColor(red: 0.16, green: 0.10, blue: 0.06, alpha: 0.95).cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
    }

    private static func drawDogEars(_ face: DetectedFace, _ cg: CGContext) {
        let d = face.eyeDistance
        let bounds = face.bounds
        let earWidth = bounds.width * 0.36
        let earHeight = earWidth * 1.25
        let earY = bounds.minY - earHeight * 0.55
        let brown = UIColor(red: 0.55, green: 0.36, blue: 0.20, alpha: 0.97)
        let pink = UIColor(red: 0.94, green: 0.66, blue: 0.66, alpha: 0.97)

        for side: CGFloat in [-1, 1] {
            let earX = bounds.midX + side * bounds.width * 0.38 - earWidth / 2
            let outer = CGRect(x: earX, y: earY, width: earWidth, height: earHeight)
            cg.setFillColor(brown.cgColor)
            cg.fillEllipse(in: outer)
            cg.setFillColor(pink.cgColor)
            cg.fillEllipse(in: outer.insetBy(dx: earWidth * 0.22, dy: earHeight * 0.24))
        }

        // dog nose on the snout — between eye line and mouth
        let noseAnchor: CGPoint
        if let mouth = face.mouth {
            let eyes = face.eyeCenter
            noseAnchor = CGPoint(x: (eyes.x + mouth.x) / 2, y: (eyes.y + mouth.y) / 2)
        } else {
            noseAnchor = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.62)
        }
        cg.setFillColor(UIColor.black.withAlphaComponent(0.92).cgColor)
        cg.fillEllipse(in: CGRect(
            x: noseAnchor.x - d * 0.22, y: noseAnchor.y - d * 0.15,
            width: d * 0.44, height: d * 0.30
        ))
    }

    private static func drawCrown(_ face: DetectedFace, _ cg: CGContext) {
        let bounds = face.bounds
        let width = bounds.width * 0.95
        let height = face.eyeDistance * 0.85
        let baseY = bounds.minY - face.eyeDistance * 0.15
        let leftX = bounds.midX - width / 2
        let gold = UIColor(red: 0.96, green: 0.77, blue: 0.26, alpha: 0.97)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: leftX, y: baseY))
        // three spikes
        for spike in 0..<3 {
            let spikeLeft = leftX + width * CGFloat(spike) / 3
            let spikeMid = spikeLeft + width / 6
            let spikeRight = spikeLeft + width / 3
            path.addLine(to: CGPoint(x: spikeLeft, y: baseY - height * 0.45))
            path.addLine(to: CGPoint(x: spikeMid, y: baseY - height))
            path.addLine(to: CGPoint(x: spikeRight, y: baseY - height * 0.45))
        }
        path.addLine(to: CGPoint(x: leftX + width, y: baseY))
        path.close()

        cg.setFillColor(gold.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()

        // jewel dots on the spike tips
        cg.setFillColor(UIColor(red: 0.85, green: 0.22, blue: 0.30, alpha: 0.97).cgColor)
        let dotR = face.eyeDistance * 0.09
        for spike in 0..<3 {
            let tipX = leftX + width * CGFloat(spike) / 3 + width / 6
            cg.fillEllipse(in: CGRect(x: tipX - dotR, y: baseY - height - dotR, width: dotR * 2, height: dotR * 2))
        }
    }

    private static func drawHearts(_ face: DetectedFace, _ cg: CGContext) {
        let d = face.eyeDistance
        let center = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
        let orbit = face.bounds.width * 0.78
        let red = UIColor(red: 0.92, green: 0.26, blue: 0.38, alpha: 0.95)

        // deterministic ring of hearts around the face — no randomness, so
        // a retake with the same pose looks the same
        let angles: [CGFloat] = [-135, -90, -45, -160, -20].map { $0 * .pi / 180 }
        cg.setFillColor(red.cgColor)
        for (index, angle) in angles.enumerated() {
            let size = d * (0.30 + CGFloat(index % 3) * 0.08)
            let position = CGPoint(
                x: center.x + cos(angle) * orbit,
                y: center.y + sin(angle) * orbit
            )
            cg.addPath(heartPath(center: position, size: size).cgPath)
            cg.fillPath()
        }
    }

    private static func heartPath(center: CGPoint, size: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let w = size, h = size
        let top = CGPoint(x: center.x, y: center.y - h * 0.25)
        path.move(to: CGPoint(x: center.x, y: center.y + h * 0.5))
        path.addCurve(
            to: top,
            controlPoint1: CGPoint(x: center.x - w * 0.9, y: center.y),
            controlPoint2: CGPoint(x: center.x - w * 0.5, y: center.y - h * 0.75)
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: center.y + h * 0.5),
            controlPoint1: CGPoint(x: center.x + w * 0.5, y: center.y - h * 0.75),
            controlPoint2: CGPoint(x: center.x + w * 0.9, y: center.y)
        )
        path.close()
        return path
    }
}

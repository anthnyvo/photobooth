import UIKit
import Vision

/// Guest-selectable AR-style props, anchored to detected faces and burned
/// into the saved file. Detection is Apple's Vision framework — the full
/// facial-landmark constellation (eye/lip/contour points) plus face roll,
/// so props pin to real features and rotate with head tilt instead of
/// floating near a bounding box. All on-device; nothing leaves the iPad.
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

/// One face in image pixel coordinates (UIKit orientation, origin
/// top-left), with the geometry the prop renderer draws against.
struct DetectedFace {
    let bounds: CGRect
    let leftEye: CGPoint?
    let rightEye: CGPoint?
    let mouth: CGPoint?
    /// Head tilt in radians (positive = clockwise on screen), measured
    /// from the eye line — props rotate with it.
    let roll: CGFloat
    let hasSmile: Bool

    var eyeCenter: CGPoint {
        guard let leftEye, let rightEye else {
            return CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.4)
        }
        return CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    }

    var eyeDistance: CGFloat {
        guard let leftEye, let rightEye else { return bounds.width * 0.42 }
        return hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
    }
}

enum FaceVision {
    enum Accuracy {
        case still, live
    }

    /// Vision landmark detection in UIKit pixel coordinates. Same code for
    /// stills and live frames — Vision is fast enough for the live loop at
    /// the frame sizes the booth feeds it (~1MP live view, ~2MP stills).
    static func detectFaces(in cgImage: CGImage, accuracy: Accuracy) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        return observations.map { face in
            // boundingBox is normalized, origin bottom-left → pixel top-left
            let box = face.boundingBox
            let bounds = CGRect(
                x: box.origin.x * width,
                y: height - (box.origin.y + box.height) * height,
                width: box.width * width,
                height: box.height * height
            )

            func meanPoint(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let region, region.pointCount > 0 else { return nil }
                // normalizedPoints are relative to the bounding box,
                // origin bottom-left.
                var sumX: CGFloat = 0, sumY: CGFloat = 0
                for p in region.normalizedPoints {
                    sumX += p.x
                    sumY += p.y
                }
                let nx = sumX / CGFloat(region.pointCount)
                let ny = sumY / CGFloat(region.pointCount)
                return CGPoint(
                    x: (box.origin.x + nx * box.width) * width,
                    y: height - (box.origin.y + ny * box.height) * height
                )
            }

            let leftEye = meanPoint(face.landmarks?.leftEye)
            let rightEye = meanPoint(face.landmarks?.rightEye)
            let mouth = meanPoint(face.landmarks?.outerLips)

            // Roll from the eye line — the observation's own roll property
            // exists on newer OS revisions, but the eye line works
            // everywhere and matches what the renderer anchors to anyway.
            var roll: CGFloat = 0
            if let l = leftEye, let r = rightEye {
                roll = atan2(r.y - l.y, r.x - l.x)
            }

            // Smile from lip geometry: mouth corners sitting above the lip
            // centroid reads as a smile. Approximate but serviceable for
            // the smile shutter; Vision has no smile classifier.
            var smiling = false
            if let lips = face.landmarks?.outerLips, lips.pointCount >= 6, let mouthCenter = mouth {
                let points = lips.normalizedPoints.map { p in
                    CGPoint(
                        x: (box.origin.x + p.x * box.width) * width,
                        y: height - (box.origin.y + p.y * box.height) * height
                    )
                }
                let leftCorner = points.min(by: { $0.x < $1.x })!
                let rightCorner = points.max(by: { $0.x < $1.x })!
                let cornerLift = mouthCenter.y - (leftCorner.y + rightCorner.y) / 2
                let mouthWidth = rightCorner.x - leftCorner.x
                smiling = mouthWidth > 0 && cornerLift > mouthWidth * 0.06
            }

            return DetectedFace(
                bounds: bounds,
                leftEye: leftEye,
                rightEye: rightEye,
                mouth: mouth,
                roll: roll,
                hasSmile: smiling
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

        image = image.downscaled(maxWidth: 2000)
        guard let cgImage = image.cgImage else { return photoData }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let faces = FaceVision.detectFaces(in: cgImage, accuracy: accuracy)
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
    /// pixels — the live-view AR preview layer.
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

    /// All props draw in FACE-LOCAL space: the context is translated to the
    /// eye center and rotated by the head's roll, so every shape below can
    /// assume an upright face with eyes on the horizontal axis — tilting
    /// your head tilts the prop with it.
    private static func draw(_ prop: PhotoProp, on face: DetectedFace, in cg: CGContext) {
        let center = face.eyeCenter
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: face.roll)

        let d = face.eyeDistance
        // Anchors in face-local space (origin = eye center, +y down):
        let localLeftEye = CGPoint(x: -d / 2, y: 0)
        let localRightEye = CGPoint(x: d / 2, y: 0)
        // Mouth: rotate the real point into local space when we have it.
        let localMouth: CGPoint
        if let mouth = face.mouth {
            let dx = mouth.x - center.x
            let dy = mouth.y - center.y
            let cosR = cos(-face.roll), sinR = sin(-face.roll)
            localMouth = CGPoint(x: dx * cosR - dy * sinR, y: dx * sinR + dy * cosR)
        } else {
            localMouth = CGPoint(x: 0, y: d * 1.1)
        }
        let faceWidth = face.bounds.width
        // Head top relative to the eye line — landmarks put the eye line
        // roughly 45% down the detection box.
        let localTop = -face.bounds.height * 0.55

        switch prop {
        case .none:
            break
        case .sunglasses:
            drawSunglasses(d: d, left: localLeftEye, right: localRightEye, cg)
        case .mustache:
            drawMustache(d: d, mouth: localMouth, cg)
        case .dogEars:
            drawDogEars(d: d, faceWidth: faceWidth, top: localTop, mouth: localMouth, cg)
        case .crown:
            drawCrown(d: d, faceWidth: faceWidth, top: localTop, cg)
        case .hearts:
            drawHearts(d: d, faceWidth: faceWidth, cg)
        }
        cg.restoreGState()
    }

    // MARK: - Individual props (face-local space: origin at eye center,
    // eyes on the x-axis, +y toward the chin)

    private static func drawSunglasses(d: CGFloat, left: CGPoint, right: CGPoint, _ cg: CGContext) {
        let lensRadius = d * 0.34
        cg.setFillColor(UIColor.black.withAlphaComponent(0.88).cgColor)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(d * 0.06)

        for eye in [left, right] {
            cg.fillEllipse(in: CGRect(
                x: eye.x - lensRadius, y: eye.y - lensRadius * 0.9,
                width: lensRadius * 2, height: lensRadius * 1.8
            ))
        }
        cg.move(to: CGPoint(x: left.x + lensRadius, y: -lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: right.x - lensRadius, y: -lensRadius * 0.2))
        cg.strokePath()
        cg.move(to: CGPoint(x: left.x - lensRadius, y: -lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: left.x - lensRadius - d * 0.35, y: -lensRadius * 0.45))
        cg.move(to: CGPoint(x: right.x + lensRadius, y: -lensRadius * 0.2))
        cg.addLine(to: CGPoint(x: right.x + lensRadius + d * 0.35, y: -lensRadius * 0.45))
        cg.strokePath()
    }

    private static func drawMustache(d: CGFloat, mouth: CGPoint, _ cg: CGContext) {
        let center = CGPoint(x: mouth.x, y: mouth.y - d * 0.28)
        let lobeWidth = d * 0.72
        let lobeHeight = d * 0.30

        let path = UIBezierPath()
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

    private static func drawDogEars(d: CGFloat, faceWidth: CGFloat, top: CGFloat, mouth: CGPoint, _ cg: CGContext) {
        let earWidth = faceWidth * 0.36
        let earHeight = earWidth * 1.25
        let earY = top - earHeight * 0.35
        let brown = UIColor(red: 0.55, green: 0.36, blue: 0.20, alpha: 0.97)
        let pink = UIColor(red: 0.94, green: 0.66, blue: 0.66, alpha: 0.97)

        for side: CGFloat in [-1, 1] {
            let earX = side * faceWidth * 0.38 - earWidth / 2
            let outer = CGRect(x: earX, y: earY, width: earWidth, height: earHeight)
            cg.setFillColor(brown.cgColor)
            cg.fillEllipse(in: outer)
            cg.setFillColor(pink.cgColor)
            cg.fillEllipse(in: outer.insetBy(dx: earWidth * 0.22, dy: earHeight * 0.24))
        }

        // dog nose midway between the eye line and the mouth
        let nose = CGPoint(x: mouth.x / 2, y: mouth.y * 0.5)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.92).cgColor)
        cg.fillEllipse(in: CGRect(
            x: nose.x - d * 0.22, y: nose.y - d * 0.15,
            width: d * 0.44, height: d * 0.30
        ))
    }

    private static func drawCrown(d: CGFloat, faceWidth: CGFloat, top: CGFloat, _ cg: CGContext) {
        let width = faceWidth * 0.95
        let height = d * 0.85
        let baseY = top - d * 0.05
        let leftX = -width / 2
        let gold = UIColor(red: 0.96, green: 0.77, blue: 0.26, alpha: 0.97)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: leftX, y: baseY))
        for spike in 0..<3 {
            let spikeLeft = leftX + width * CGFloat(spike) / 3
            path.addLine(to: CGPoint(x: spikeLeft, y: baseY - height * 0.45))
            path.addLine(to: CGPoint(x: spikeLeft + width / 6, y: baseY - height))
            path.addLine(to: CGPoint(x: spikeLeft + width / 3, y: baseY - height * 0.45))
        }
        path.addLine(to: CGPoint(x: leftX + width, y: baseY))
        path.close()

        cg.setFillColor(gold.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()

        cg.setFillColor(UIColor(red: 0.85, green: 0.22, blue: 0.30, alpha: 0.97).cgColor)
        let dotR = d * 0.09
        for spike in 0..<3 {
            let tipX = leftX + width * CGFloat(spike) / 3 + width / 6
            cg.fillEllipse(in: CGRect(x: tipX - dotR, y: baseY - height - dotR, width: dotR * 2, height: dotR * 2))
        }
    }

    private static func drawHearts(d: CGFloat, faceWidth: CGFloat, _ cg: CGContext) {
        let orbit = faceWidth * 0.78
        let red = UIColor(red: 0.92, green: 0.26, blue: 0.38, alpha: 0.95)

        let angles: [CGFloat] = [-135, -90, -45, -160, -20].map { $0 * .pi / 180 }
        cg.setFillColor(red.cgColor)
        for (index, angle) in angles.enumerated() {
            let size = d * (0.30 + CGFloat(index % 3) * 0.08)
            let position = CGPoint(x: cos(angle) * orbit, y: sin(angle) * orbit + d * 0.4)
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

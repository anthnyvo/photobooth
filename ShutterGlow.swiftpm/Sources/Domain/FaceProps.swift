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
    case flowerCrown
    case bunnyEars
    case catWhiskers
    case devilHorns
    case rainbow

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "No Prop"
        case .sunglasses: "Shades"
        case .mustache: "Mustache"
        case .dogEars: "Dog Ears"
        case .crown: "Crown"
        case .hearts: "Hearts"
        case .flowerCrown: "Flower Crown"
        case .bunnyEars: "Bunny Ears"
        case .catWhiskers: "Cat"
        case .devilHorns: "Devil"
        case .rainbow: "Rainbow"
        }
    }
}

/// One face in image pixel coordinates (UIKit orientation, origin
/// top-left), with the geometry the prop renderer draws against.
struct DetectedFace: Sendable {
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

/// Temporal smoothing for the live prop loop. Raw per-frame detections
/// jitter by a few pixels and occasionally miss a frame entirely, which
/// reads as props vibrating and blinking. Exponential smoothing toward each
/// new sample makes props glide, and a short grace window holds the last
/// good faces through detection misses so the overlay never flickers.
/// Coordinates are only comparable across scans of the same pixel space —
/// the caller resets the smoother whenever the frame size changes.
struct FaceSmoother: Sendable {
    var pixelSize: CGSize = .zero
    private var faces: [DetectedFace] = []
    private var misses = 0

    /// Weight of the newest sample. At ~11 scans/sec, 0.45 settles on a new
    /// position within ~3 frames — smooth without visible lag.
    private static let alpha: CGFloat = 0.45
    /// Consecutive empty detections tolerated before the overlay drops.
    private static let maxMisses = 3

    mutating func update(with detected: [DetectedFace]) -> [DetectedFace] {
        guard !detected.isEmpty else {
            misses += 1
            if misses > Self.maxMisses { faces = [] }
            return faces
        }
        misses = 0
        var previous = faces
        faces = detected.map { raw in
            // Nearest prior face within one face-width = same person.
            if let index = previous.indices.min(by: {
                Self.distance(previous[$0], raw) < Self.distance(previous[$1], raw)
            }), Self.distance(previous[index], raw) < raw.bounds.width {
                return Self.smooth(old: previous.remove(at: index), new: raw)
            }
            return raw
        }
        return faces
    }

    mutating func reset() {
        faces = []
        misses = 0
        pixelSize = .zero
    }

    private static func distance(_ a: DetectedFace, _ b: DetectedFace) -> CGFloat {
        hypot(a.eyeCenter.x - b.eyeCenter.x, a.eyeCenter.y - b.eyeCenter.y)
    }

    private static func smooth(old: DetectedFace, new: DetectedFace) -> DetectedFace {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * alpha }
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: lerp(a.x, b.x), y: lerp(a.y, b.y))
        }
        func lerp(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            guard let a, let b else { return b ?? a }
            return lerp(a, b)
        }
        return DetectedFace(
            bounds: CGRect(
                x: lerp(old.bounds.origin.x, new.bounds.origin.x),
                y: lerp(old.bounds.origin.y, new.bounds.origin.y),
                width: lerp(old.bounds.width, new.bounds.width),
                height: lerp(old.bounds.height, new.bounds.height)
            ),
            leftEye: lerp(old.leftEye, new.leftEye),
            rightEye: lerp(old.rightEye, new.rightEye),
            mouth: lerp(old.mouth, new.mouth),
            roll: lerp(old.roll, new.roll),
            hasSmile: new.hasSmile
        )
    }
}

enum FaceVision {
    enum Accuracy {
        case still, live
    }

    /// Decodes a live-view JPEG down to detection resolution. Vision's
    /// landmark accuracy holds well below full live-view size while its
    /// cost scales with pixel area, so scanning at ≤1024px instead of the
    /// raw frame cuts each pass to a fraction — this, not scan frequency,
    /// was the real cost of the live loop. Rendered at scale 1 so pixel
    /// dimensions are exact and stable across frames (the smoother
    /// compares coordinates between scans).
    static func detectionImage(from data: Data, maxWidth: CGFloat = 1024) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        guard let cgImage = image.cgImage else { return nil }
        guard CGFloat(cgImage.width) > maxWidth else { return cgImage }

        let target = CGSize(
            width: maxWidth,
            height: (maxWidth * CGFloat(cgImage.height) / CGFloat(cgImage.width)).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = autoreleasepool {
            UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        }
        return small.cgImage
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

    /// One live-loop pass: detect at reduced resolution, smooth against the
    /// previous scans, render props-only on a transparent canvas matching
    /// the detection frame's aspect (the preview layers it `scaledToFill`,
    /// so only aspect matters, and rendering small is cheaper too).
    /// Value-in/value-out smoother keeps this callable from a detached
    /// task with no shared state.
    static func liveScan(
        _ prop: PhotoProp,
        frameData: Data,
        smoother: FaceSmoother
    ) -> (overlay: UIImage?, smoother: FaceSmoother) {
        var smoother = smoother
        guard prop != .none,
              let cgImage = FaceVision.detectionImage(from: frameData) else {
            smoother.reset()
            return (nil, smoother)
        }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        if pixelSize != smoother.pixelSize {
            smoother.reset()
            smoother.pixelSize = pixelSize
        }
        let faces = smoother.update(with: FaceVision.detectFaces(in: cgImage, accuracy: .live))
        guard !faces.isEmpty else { return (nil, smoother) }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let overlay = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let cg = context.cgContext
            for face in faces {
                draw(prop, on: face, in: cg)
            }
        }
        return (overlay, smoother)
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
        case .flowerCrown:
            drawFlowerCrown(d: d, faceWidth: faceWidth, top: localTop, cg)
        case .bunnyEars:
            drawBunnyEars(d: d, faceWidth: faceWidth, top: localTop, cg)
        case .catWhiskers:
            drawCatWhiskers(d: d, faceWidth: faceWidth, top: localTop, mouth: localMouth, cg)
        case .devilHorns:
            drawDevilHorns(d: d, faceWidth: faceWidth, top: localTop, cg)
        case .rainbow:
            drawRainbow(d: d, mouth: localMouth, cg)
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

    // MARK: - Snapchat-style props

    private static func drawFlowerCrown(d: CGFloat, faceWidth: CGFloat, top: CGFloat, _ cg: CGContext) {
        let baseY = top + d * 0.12
        let petalColors: [UIColor] = [
            UIColor(red: 0.96, green: 0.55, blue: 0.68, alpha: 0.97),
            UIColor(red: 0.99, green: 0.85, blue: 0.35, alpha: 0.97),
            UIColor(red: 0.85, green: 0.42, blue: 0.85, alpha: 0.97),
            UIColor(red: 0.99, green: 0.85, blue: 0.35, alpha: 0.97),
            UIColor(red: 0.96, green: 0.55, blue: 0.68, alpha: 0.97),
        ]
        let count = petalColors.count
        cg.setFillColor(UIColor(red: 0.30, green: 0.55, blue: 0.28, alpha: 0.9).cgColor)
        for i in 0..<(count - 1) {
            let x0 = faceWidth * (CGFloat(i) / CGFloat(count - 1) - 0.5) * 0.86
            let x1 = faceWidth * (CGFloat(i + 1) / CGFloat(count - 1) - 0.5) * 0.86
            let leaf = UIBezierPath(ovalIn: CGRect(
                x: (x0 + x1) / 2 - d * 0.08, y: baseY - d * 0.06,
                width: d * 0.16, height: d * 0.1
            ))
            cg.addPath(leaf.cgPath)
            cg.fillPath()
        }
        for (i, color) in petalColors.enumerated() {
            let x = faceWidth * (CGFloat(i) / CGFloat(count - 1) - 0.5) * 0.86
            let dip = abs(CGFloat(i) - CGFloat(count - 1) / 2)
            let y = baseY + dip * d * 0.045
            drawFlower(at: CGPoint(x: x, y: y), size: d * 0.24, petalColor: color, cg)
        }
    }

    private static func drawFlower(at center: CGPoint, size: CGFloat, petalColor: UIColor, _ cg: CGContext) {
        cg.setFillColor(petalColor.cgColor)
        let petalCount = 5
        for i in 0..<petalCount {
            let angle = CGFloat(i) / CGFloat(petalCount) * 2 * .pi
            let px = center.x + cos(angle) * size * 0.4
            let py = center.y + sin(angle) * size * 0.4
            cg.fillEllipse(in: CGRect(x: px - size * 0.32, y: py - size * 0.32, width: size * 0.64, height: size * 0.64))
        }
        cg.setFillColor(UIColor(red: 0.98, green: 0.78, blue: 0.20, alpha: 1).cgColor)
        cg.fillEllipse(in: CGRect(x: center.x - size * 0.22, y: center.y - size * 0.22, width: size * 0.44, height: size * 0.44))
    }

    private static func drawBunnyEars(d: CGFloat, faceWidth: CGFloat, top: CGFloat, _ cg: CGContext) {
        let earWidth = faceWidth * 0.20
        let earHeight = earWidth * 3.1
        let earY = top - earHeight * 0.82
        let white = UIColor.white.withAlphaComponent(0.97)
        let pink = UIColor(red: 0.94, green: 0.62, blue: 0.68, alpha: 0.95)

        for side: CGFloat in [-1, 1] {
            let earX = side * faceWidth * 0.22 - earWidth / 2
            let outer = CGRect(x: earX, y: earY, width: earWidth, height: earHeight)
            cg.setFillColor(white.cgColor)
            cg.addPath(UIBezierPath(roundedRect: outer, cornerRadius: earWidth / 2).cgPath)
            cg.fillPath()
            let inner = outer.insetBy(dx: earWidth * 0.28, dy: earHeight * 0.14)
            cg.setFillColor(pink.cgColor)
            cg.addPath(UIBezierPath(roundedRect: inner, cornerRadius: inner.width / 2).cgPath)
            cg.fillPath()
        }
    }

    private static func drawCatWhiskers(d: CGFloat, faceWidth: CGFloat, top: CGFloat, mouth: CGPoint, _ cg: CGContext) {
        let earWidth = faceWidth * 0.30
        let earHeight = earWidth * 1.1
        let earY = top - earHeight * 0.05
        let gray = UIColor(red: 0.42, green: 0.40, blue: 0.44, alpha: 0.95)
        let pinkInner = UIColor(red: 0.93, green: 0.62, blue: 0.68, alpha: 0.95)

        for side: CGFloat in [-1, 1] {
            let baseX = side * faceWidth * 0.30
            let outer = UIBezierPath()
            outer.move(to: CGPoint(x: baseX - earWidth / 2, y: earY + earHeight))
            outer.addLine(to: CGPoint(x: baseX, y: earY))
            outer.addLine(to: CGPoint(x: baseX + earWidth / 2, y: earY + earHeight))
            outer.close()
            cg.setFillColor(gray.cgColor)
            cg.addPath(outer.cgPath)
            cg.fillPath()

            let s: CGFloat = 0.55
            let inner = UIBezierPath()
            inner.move(to: CGPoint(x: baseX - earWidth * s / 2, y: earY + earHeight))
            inner.addLine(to: CGPoint(x: baseX, y: earY + earHeight * (1 - s)))
            inner.addLine(to: CGPoint(x: baseX + earWidth * s / 2, y: earY + earHeight))
            inner.close()
            cg.setFillColor(pinkInner.cgColor)
            cg.addPath(inner.cgPath)
            cg.fillPath()
        }

        let nose = UIBezierPath()
        nose.move(to: CGPoint(x: mouth.x, y: mouth.y - d * 0.28))
        nose.addLine(to: CGPoint(x: mouth.x - d * 0.09, y: mouth.y - d * 0.15))
        nose.addLine(to: CGPoint(x: mouth.x + d * 0.09, y: mouth.y - d * 0.15))
        nose.close()
        cg.setFillColor(pinkInner.cgColor)
        cg.addPath(nose.cgPath)
        cg.fillPath()

        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        cg.setLineWidth(d * 0.035)
        cg.setLineCap(.round)
        for side: CGFloat in [-1, 1] {
            for i in 0..<3 {
                let yOff = mouth.y - d * 0.05 + CGFloat(i) * d * 0.12
                cg.move(to: CGPoint(x: side * d * 0.18, y: yOff))
                cg.addLine(to: CGPoint(x: side * d * (0.75 + CGFloat(i) * 0.08), y: yOff - d * 0.05 + CGFloat(i) * d * 0.03))
            }
        }
        cg.strokePath()
    }

    private static func drawDevilHorns(d: CGFloat, faceWidth: CGFloat, top: CGFloat, _ cg: CGContext) {
        let red = UIColor(red: 0.82, green: 0.14, blue: 0.18, alpha: 0.95)
        let hornWidth = faceWidth * 0.16
        let hornHeight = hornWidth * 1.7
        let baseY = top + d * 0.12

        for side: CGFloat in [-1, 1] {
            let baseX = side * faceWidth * 0.26
            let path = UIBezierPath()
            path.move(to: CGPoint(x: baseX - hornWidth / 2, y: baseY))
            path.addQuadCurve(
                to: CGPoint(x: baseX + side * hornWidth * 0.35, y: baseY - hornHeight),
                controlPoint: CGPoint(x: baseX - side * hornWidth * 0.15, y: baseY - hornHeight * 0.65)
            )
            path.addQuadCurve(
                to: CGPoint(x: baseX + hornWidth / 2, y: baseY),
                controlPoint: CGPoint(x: baseX + side * hornWidth * 0.95, y: baseY - hornHeight * 0.5)
            )
            path.close()
            cg.setFillColor(red.cgColor)
            cg.addPath(path.cgPath)
            cg.fillPath()
        }
    }

    private static func drawRainbow(d: CGFloat, mouth: CGPoint, _ cg: CGContext) {
        let colors: [UIColor] = [
            UIColor(red: 0.91, green: 0.20, blue: 0.24, alpha: 0.9),
            UIColor(red: 0.97, green: 0.55, blue: 0.15, alpha: 0.9),
            UIColor(red: 0.98, green: 0.85, blue: 0.20, alpha: 0.9),
            UIColor(red: 0.30, green: 0.70, blue: 0.35, alpha: 0.9),
            UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 0.9),
            UIColor(red: 0.55, green: 0.30, blue: 0.75, alpha: 0.9),
        ]
        let radius = d * 1.3
        let lineWidth = d * 0.16
        cg.setLineCap(.round)
        for (i, color) in colors.enumerated() {
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(lineWidth)
            let r = radius - CGFloat(i) * lineWidth * 0.95
            cg.addArc(center: mouth, radius: r, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
            cg.strokePath()
        }
    }
}

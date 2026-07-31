import Foundation
import AVFoundation
import UIKit

public enum UVCWebcamError: Error, LocalizedError {
    case cameraAccessDenied
    case noExternalCamera
    case sessionConfigFailed
    case noFrameAvailable

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied: "Camera access denied — enable it in Settings → ShutterGlow → Camera"
        case .noExternalCamera: "No external USB camera found — put the camera in USB Streaming mode and check the cable"
        case .sessionConfigFailed: "Couldn't configure the camera's video stream"
        case .noFrameAvailable: "No video frame available yet"
        }
    }
}

/// Cameras with a UVC/UAC "webcam mode" (Sony's USB Streaming, and the
/// equivalent on other bodies) exposed as a plain external camera through
/// AVFoundation — iPadOS 17+'s `.external` AVCaptureDevice type. No vendor
/// SDK, no PTP at all.
///
/// This exists because Phase 0 concluded PTP-based live view was a dead end
/// on iOS. That conclusion is IN DOUBT as of 2026-07-31 (see docs/PHASE0.md)
/// and this path may turn out to be unnecessary. It stands on its own
/// regardless: UVC touches no PTP at all, so live view AND capture come from
/// the same video stream.
///
/// Worth recording, since it was researched on 2026-07-31 and is settled:
/// UVC webcam mode and PTP are mutually exclusive on Sony, Canon and Nikon.
/// All three make USB mode a one-of-N menu selection, and entering streaming
/// tears the PTP function down — Nikon states it outright ("communications
/// with the computer/smart device other than the streaming software"
/// unavailable while streaming). So this path can never be combined with a
/// PTP path over the same cable, whatever happens to the Phase 0 question.
///
/// Real trade-off, not hidden: "capture" here freezes the newest video
/// frame rather than firing the camera's actual mechanical shutter — no
/// hot-shoe flash sync, and resolution is capped at the stream's video
/// resolution (e.g. ~8MP at the a7 IV's 4K UVC setting), not the sensor's
/// full still resolution.
public actor UVCWebcamCamera: TetheredCamera {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let delegate = FrameDelegate()
    private var configured = false

    public init() {}

    public func enterRemoteMode() async throws {
        guard !configured else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw UVCWebcamError.cameraAccessDenied
            }
        case .denied, .restricted:
            throw UVCWebcamError.cameraAccessDenied
        @unknown default:
            throw UVCWebcamError.cameraAccessDenied
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first else {
            throw UVCWebcamError.noExternalCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw UVCWebcamError.sessionConfigFailed
        }
        session.addInput(input)

        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.anthonyvo.shutterglow.uvcframes"))
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            throw UVCWebcamError.sessionConfigFailed
        }
        session.addOutput(output)

        configured = true
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let stream = delegate.makeStream()
        if !session.isRunning {
            session.startRunning()
        }
        return stream
    }

    /// Freezes the newest frame the live stream has already decoded —
    /// no separate shutter command, see the type-level doc comment.
    public func capturePhoto() async throws -> Data {
        guard let jpeg = delegate.latestJPEG else {
            throw UVCWebcamError.noFrameAvailable
        }
        return jpeg
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        // UVC webcam mode reports no battery telemetry.
    }

    public func disconnect() {
        session.stopRunning()
        delegate.finish()
        configured = false
    }
}

/// Bridges AVCaptureVideoDataOutputSampleBufferDelegate's callback-queue
/// delivery into an AsyncStream — same shape as SonyCamera's
/// ChunkedHTTPStream. `@unchecked Sendable`: `continuation` is only ever
/// touched from the fixed serial queue passed to `setSampleBufferDelegate`
/// (actor calls into `makeStream`/`finish` happen before that queue starts
/// delivering frames or after `disconnect` stops it); `latestJPEG` is
/// genuinely written and read from different queues, so it's guarded by a
/// lock rather than relying on delivery ordering.
private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let ciContext = CIContext()
    private var continuation: AsyncStream<Data>.Continuation?
    private let lock = NSLock()
    private var _latestJPEG: Data?

    var latestJPEG: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _latestJPEG
    }

    func makeStream() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        return stream
    }

    func finish() {
        continuation?.finish()
        continuation = nil
        lock.lock()
        _latestJPEG = nil
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92) else { return }

        lock.lock()
        _latestJPEG = jpeg
        lock.unlock()
        continuation?.yield(jpeg)
    }
}

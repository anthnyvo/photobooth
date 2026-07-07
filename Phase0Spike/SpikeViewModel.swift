import Foundation
import SwiftUI
import CameraKit

/// Drives the Phase 0 spike screen. One state machine, heavy logging —
/// the whole point is to learn what the EOS R actually does over
/// ImageCaptureCore passthrough.
@MainActor
final class SpikeViewModel: ObservableObject {

    enum Step: String {
        case waitingForCamera = "Plug in the EOS R (powered on, Auto/PTP USB mode)"
        case sessionOpening = "Camera found — opening session…"
        case indexing = "Session open — waiting for content catalog (this gates PTP access)"
        case ready = "READY — PTP passthrough authorized"
        case remoteMode = "Remote mode active"
        case liveView = "LIVE VIEW streaming"
        case disconnected = "Camera disconnected — replug to test recovery"
    }

    @Published var step: Step = .waitingForCamera
    @Published var logLines: [String] = []
    @Published var liveViewImage: UIImage?
    @Published var lastCapture: UIImage?
    @Published var fps: Double = 0
    @Published var captureRoundTripSeconds: Double?
    @Published var isCapturing = false

    private let transport = ICCTransport()
    private lazy var camera = EOSCamera(transport: transport)
    private var liveViewConsumer: Task<Void, Never>?
    private var fpsTimer: Timer?

    func start() {
        log("spike started — \(Date().formatted())")
        Task {
            await camera.setLogSink { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
        }
        Task { await consumeTransportEvents() }
        transport.start()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = await self.camera.liveViewStats.fps
            }
        }
    }

    private func consumeTransportEvents() async {
        for await event in transport.events {
            switch event {
            case .deviceFound(let name):
                log("camera found: \(name)")
                step = .sessionOpening
            case .sessionOpened:
                log("session opened — waiting for deviceDidBecomeReady (do NOT send PTP yet)")
                step = .indexing
            case .ready:
                log("deviceDidBecomeReady fired — passthrough authorized")
                step = .ready
                await autoConnect()
            case .deviceRemoved:
                log("!! camera removed — recovery test: replug the cable")
                step = .disconnected
                liveViewConsumer?.cancel()
                liveViewImage = nil
                await camera.disconnect()
            case .fileAdded(let name, let size):
                log("file announced: \(name) (\(size) bytes)")
            case .log(let line):
                log(line)
            }
        }
    }

    /// The Phase 0 happy path, run automatically on ready:
    /// remote mode -> live view. Capture stays manual (button).
    private func autoConnect() async {
        do {
            try await camera.enterRemoteMode()
            step = .remoteMode
            try await startLiveView()
        } catch {
            log("!! connect failed: \(error)")
        }
    }

    func startLiveView() async throws {
        let frames = try await camera.startLiveView()
        step = .liveView
        liveViewConsumer?.cancel()
        liveViewConsumer = Task { [weak self] in
            for await jpeg in frames {
                guard let self else { return }
                if let image = UIImage(data: jpeg) {
                    await MainActor.run { self.liveViewImage = image }
                }
            }
        }
    }

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        let started = ContinuousClock.now
        Task {
            defer { isCapturing = false }
            do {
                let data = try await camera.capturePhoto()
                let elapsed = started.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) +
                    Double(elapsed.components.attoseconds) / 1e18
                captureRoundTripSeconds = seconds
                lastCapture = UIImage(data: data)
                log(String(format: "capture OK: %d bytes in %.2fs (budget: 5s)", data.count, seconds))
            } catch {
                log("!! capture failed: \(error)")
            }
        }
    }

    func exportLog() -> String {
        logLines.joined(separator: "\n")
    }

    private func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        print("[SPIKE] \(line)")
    }
}

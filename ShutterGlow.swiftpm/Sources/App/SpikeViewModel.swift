import Foundation
import SwiftUI
import CameraKit

/// Drives the Phase 0 spike screen. One state machine, heavy logging —
/// the whole point is to learn what the EOS R actually does over whichever
/// transport is under test.
@MainActor
final class SpikeViewModel: ObservableObject {

    enum Step: String {
        case choosingConnection = "Choose USB or Wi-Fi to begin"
        case waitingForCamera = "Waiting for camera…"
        case sessionOpening = "Camera found — opening session…"
        case indexing = "Session open — waiting for content catalog (this gates PTP access)"
        case ready = "READY — PTP passthrough authorized"
        case remoteMode = "Remote mode active"
        case liveView = "LIVE VIEW streaming"
        case disconnected = "Camera disconnected — replug to test recovery"
        case failed = "Connection failed — see log"
    }

    @Published var step: Step = .choosingConnection
    @Published var logLines: [String] = []
    @Published var liveViewImage: UIImage?
    @Published var lastCapture: UIImage?
    @Published var fps: Double = 0
    @Published var captureRoundTripSeconds: Double?
    @Published var isCapturing = false
    @Published var cameraIPText: String = "192.168.1.1"

    private var transport: (any PTPTransport)?
    private var camera: EOSCamera?
    private var liveViewConsumer: Task<Void, Never>?
    private var eventConsumer: Task<Void, Never>?
    private var fpsTimer: Timer?

    // MARK: - Connection entry points

    func startUSB() {
        log("spike started (USB) — \(Date().formatted())")
        step = .waitingForCamera
        let usbTransport = ICCTransport()
        wireUp(transport: usbTransport)
        usbTransport.start()
    }

    func startWiFi() {
        log("spike started (Wi-Fi) — \(Date().formatted()), target \(cameraIPText)")
        step = .waitingForCamera
        let wifiTransport = PTPIPTransport(host: cameraIPText)
        wireUp(transport: wifiTransport)
        Task {
            do {
                try await wifiTransport.connect()
            } catch {
                log("!! Wi-Fi connect failed: \(error)")
                step = .failed
            }
        }
    }

    private func wireUp(transport: any PTPTransport) {
        self.transport = transport
        let cam = EOSCamera(transport: transport)
        self.camera = cam
        Task {
            await cam.setLogSink { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
        }
        eventConsumer?.cancel()
        eventConsumer = Task { await self.consumeTransportEvents(transport.events) }

        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let cam = self.camera else { return }
                self.fps = await cam.liveViewStats.fps
            }
        }
    }

    private func consumeTransportEvents(_ events: AsyncStream<TransportEvent>) async {
        for await event in events {
            switch event {
            case .deviceFound(let name):
                log("camera found: \(name)")
                step = .sessionOpening
            case .sessionOpened:
                log("session opened — waiting for deviceDidBecomeReady (do NOT send PTP yet)")
                step = .indexing
            case .ready:
                log("ready — passthrough authorized")
                step = .ready
                await autoConnect()
            case .deviceRemoved:
                log("!! camera removed — recovery test: replug/reconnect")
                step = .disconnected
                liveViewConsumer?.cancel()
                liveViewImage = nil
                await camera?.disconnect()
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
        guard let camera else { return }
        do {
            try await camera.enterRemoteMode()
            step = .remoteMode
            try await startLiveView()
        } catch {
            log("!! connect failed: \(error)")
        }
    }

    func startLiveView() async throws {
        guard let camera else { return }
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
        guard !isCapturing, let camera else { return }
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

import Foundation
import SwiftUI

/// Guest-facing flow state. Distinct from Phase0Spike's diagnostic
/// SpikeViewModel — this one drives the actual booth experience, reusing the
/// same CameraKit transport/protocol layer proven out in Phase 0.
public enum BoothStep: Equatable {
    case eventPicker
    case connecting
    case attract
    case countdown(Int)
    case capturing
    case review(URL)
    case sharing(URL)
}

@MainActor
public final class BoothViewModel: ObservableObject {
    @Published public private(set) var step: BoothStep = .eventPicker
    @Published public private(set) var config: EventConfig
    @Published public var liveViewImage: UIImage?
    @Published public var cameraIPText: String = "192.168.1.2"
    @Published public private(set) var connectionMessage: String = "Enter the camera's IP and connect"
    @Published public private(set) var lastError: String?
    /// Non-nil only mid-strip-sequence, so CaptureView can show "Shot 2 of 3"
    /// — nil (and ignored) for a normal single-shot capture.
    @Published public private(set) var stripProgress: (shot: Int, total: Int)?

    private var transport: PTPIPTransport?
    private var camera: EOSCamera?
    private var liveViewConsumer: Task<Void, Never>?
    private var eventConsumer: Task<Void, Never>?
    private var returnToAttractTask: Task<Void, Never>?

    public init(config: EventConfig = EventStorage.shared.loadCurrentOrDefault()) {
        self.config = config
    }

    public func reloadConfig() {
        config = EventStorage.shared.loadCurrentOrDefault()
    }

    // MARK: - Event picker (home screen)

    /// Switches the active event and proceeds to the camera-connect step.
    /// Loading failure (corrupt/missing config.json) is treated as "ignore
    /// this row" rather than crashing the picker — the event just won't
    /// switch and the attendant can try another or create a new one.
    public func selectEvent(_ eventId: String) {
        guard let selected = try? EventStorage.shared.load(eventId) else { return }
        EventStorage.shared.setCurrentEventId(eventId)
        config = selected
        step = .connecting
    }

    // MARK: - Connection (attendant setup step)

    public func connectCamera() {
        lastError = nil
        connectionMessage = "Connecting to \(cameraIPText)…"
        let wifiTransport = PTPIPTransport(host: cameraIPText)
        transport = wifiTransport
        let cam = EOSCamera(transport: wifiTransport)
        camera = cam

        eventConsumer?.cancel()
        eventConsumer = Task { [weak self] in
            for await event in wifiTransport.events {
                await self?.handle(event)
            }
        }

        Task {
            do {
                try await wifiTransport.connect()
            } catch {
                self.lastError = "Connect failed: \(error)"
                self.connectionMessage = "Connect failed — check the camera is in Remote control (EOS Utility) mode and the IP is correct"
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .deviceFound(let name):
            connectionMessage = "Found \(name) — starting session…"
        case .ready:
            connectionMessage = "Camera ready — starting live view…"
            await startRemoteModeAndLiveView()
        case .deviceRemoved:
            lastError = "Camera disconnected"
            step = .connecting
            connectionMessage = "Camera disconnected — reconnect to continue"
            liveViewImage = nil
        default:
            break
        }
    }

    private func startRemoteModeAndLiveView() async {
        guard let camera else { return }
        do {
            try await camera.enterRemoteMode()
            let frames = try await camera.startLiveView()
            liveViewConsumer?.cancel()
            liveViewConsumer = Task { [weak self] in
                for await jpeg in frames {
                    guard let self else { return }
                    if let image = UIImage(data: jpeg) {
                        await MainActor.run { self.liveViewImage = image }
                    }
                }
            }
            step = .attract
        } catch {
            lastError = "Remote mode / live view failed: \(error)"
        }
    }

    // MARK: - Guest flow

    public func tapToStart() {
        guard step == .attract else { return }
        returnToAttractTask?.cancel()
        EventStorage.shared.recordGuestSession(eventId: config.eventId)
        beginCountdown()
    }

    /// Kicks off one shot (normal mode) or `config.strip.shotCount` shots in
    /// sequence (strip mode). Used by both tapToStart() and retake() — a
    /// retake redoes the whole sequence, matching the pre-strip retake
    /// semantics of "start over" 1:1.
    private func beginCountdown() {
        Task { await captureSequence() }
    }

    private func captureSequence() async {
        let totalShots = config.strip.enabled ? max(2, config.strip.shotCount) : 1
        var shots: [Data] = []
        for shotIndex in 1...totalShots {
            stripProgress = totalShots > 1 ? (shotIndex, totalShots) : nil
            guard let data = await runCountdownAndCapture() else {
                // Error already reported and state already transitioned
                // (attract or reconnecting) inside runCountdownAndCapture.
                stripProgress = nil
                return
            }
            shots.append(data)
            if shotIndex < totalShots {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        stripProgress = nil
        finishCapture(shots: shots)
    }

    /// One countdown + one capture, returning the raw JPEG bytes. Extracted
    /// near-verbatim from the original single-shot performCapture() — same
    /// 20s timeout and same Wi-Fi-drop disconnect/reconnect recovery, just
    /// returning Data instead of saving/transitioning directly, so it can be
    /// called once (normal) or several times in a row (strip mode).
    private func runCountdownAndCapture() async -> Data? {
        let total = max(1, config.countdownSeconds)
        for remaining in stride(from: total, through: 1, by: -1) {
            step = .countdown(remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let camera else { return nil }
        step = .capturing
        do {
            // The underlying NWConnection reads inside capturePhoto() have no
            // timeout of their own — if Wi-Fi drops mid-capture (not a clean
            // disconnect, just goes out of range), a read can hang forever
            // waiting for bytes that will never arrive. Without this, the
            // white "flash" overlay (.capturing state) never clears — the
            // exact "stuck on a white screen" symptom found testing a
            // mid-capture Wi-Fi drop. 20s is generous over the normal ~4s
            // round trip.
            return try await withTimeout(seconds: 20) { try await camera.capturePhoto() }
        } catch {
            lastError = "Capture failed: \(error)"
            step = .attract
            // A hung/failed capture usually means the connection itself is
            // dead (that's what caused the hang in the first place) —
            // disconnecting unblocks the leaked read (NWConnection.cancel()
            // completes pending receives with an error) and self-heals by
            // reconnecting with the same IP, rather than leaving the booth
            // silently wedged until an attendant notices and manually hits
            // Connect again.
            await transport?.disconnect()
            step = .connecting
            connectionMessage = "Connection lost — reconnecting…"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            connectCamera()
            return nil
        }
    }

    /// Composites multiple shots into a strip (or passes a single shot
    /// through unchanged), burns in the overlay if configured, and saves —
    /// same end state (`.review(url)`) as the original single-shot path.
    private func finishCapture(shots: [Data]) {
        guard let firstShot = shots.first else { return }
        let composited: Data
        if shots.count > 1 {
            composited = PhotoCompositor.compositeStrip(shots) ?? firstShot
        } else {
            composited = firstShot
        }
        let branded = PhotoCompositor.applyOverlay(to: composited, config: config)
        do {
            let url = try EventStorage.shared.savePhoto(branded, eventId: config.eventId)
            step = .review(url)
        } catch {
            lastError = "Save failed: \(error)"
            step = .attract
        }
    }

    public func retake() {
        beginCountdown()
    }

    public func accept() {
        guard case .review(let url) = step else { return }
        step = .sharing(url)
    }

    /// Called from the share screen once the guest is done (or after a
    /// timeout) — back to idle, auto-return after a short delay handled by
    /// the view itself calling this on a timer.
    public func returnToAttract() {
        liveViewImage = liveViewImage // keep last frame visible during transition
        step = .attract
    }

    public func scheduleAutoReturn(after seconds: TimeInterval = 20) {
        returnToAttractTask?.cancel()
        returnToAttractTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { returnToAttract() }
        }
    }
}

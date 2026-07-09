import Foundation
import SwiftUI

/// Guest-facing flow state. Distinct from Phase0Spike's diagnostic
/// SpikeViewModel — this one drives the actual booth experience, reusing the
/// same CameraKit transport/protocol layer proven out in Phase 0.
public enum BoothStep: Equatable {
    case home
    case eventPicker
    case connecting
    case attract
    case readyToShoot
    case countdown(Int)
    case capturing
    /// Boomerang/GIF frame recording — live view stays visible (unlike the
    /// white .capturing flash) so guests can see themselves move.
    case recording
    case review(URL)
    case sharing(URL)
}

@MainActor
public final class BoothViewModel: ObservableObject {
    @Published public private(set) var step: BoothStep = .home
    @Published public private(set) var config: EventConfig
    @Published public var liveViewImage: UIImage?
    @Published public var cameraIPText: String = "192.168.1.2"
    @Published public private(set) var connectionMessage: String = "Enter the camera's IP and connect"
    @Published public private(set) var lastError: String?
    /// Non-nil only mid-strip-sequence, so CaptureView can show "Shot 2 of 3"
    /// — nil (and ignored) for a normal single-shot capture.
    @Published public private(set) var stripProgress: (shot: Int, total: Int)?
    /// Best-effort — nil until (if) the camera ever reports one. See
    /// CanonProp.batteryLevel: encoding is unverified against real hardware.
    @Published public private(set) var cameraBatteryLevel: UInt32?
    /// Guest's filter pick from the attract screen's chips — resets to
    /// Original whenever the booth returns to attract, so one guest's
    /// choice never silently carries over to the next.
    @Published public var selectedFilter: PhotoFilter = .none

    private var transport: PTPIPTransport?
    private var camera: EOSCamera?
    private var liveViewConsumer: Task<Void, Never>?
    private var eventConsumer: Task<Void, Never>?
    private var returnToAttractTask: Task<Void, Never>?
    /// Set once per guest by tapToStart and reused by retake() so a retake
    /// redoes the same choice the guest originally picked.
    private var sessionShotCount = 1
    private var sessionLayout: EventConfig.StripOptions.Layout = .vertical
    /// Non-nil = this session records a Boomerang/GIF from live view
    /// instead of firing the shutter.
    private var sessionAnimatedStyle: AnimatedStyle?
    /// Live-view JPEGs collected while `isRecordingFrames` — appended by
    /// the live-view consumer task, drained by the animated capture path.
    private var recordedFrames: [Data] = []
    private var isRecordingFrames = false

    public init(config: EventConfig = EventStorage.shared.loadCurrentOrDefault()) {
        self.config = config
    }

    public func reloadConfig() {
        config = EventStorage.shared.loadCurrentOrDefault()
    }

    /// QR sharing needs this device and the guest's phone on the same
    /// network, which only happens when the camera is joined to the venue's
    /// own Wi-Fi (infrastructure mode) — not when it's creating its own
    /// private access point. There's no direct API for "is this an AP I
    /// joined vs. a router-issued network," so this leans on the one signal
    /// available: the camera's private-AP default is always 192.168.1.x
    /// (also this app's placeholder default), so an IP in that subnet reads
    /// as "camera's own AP" and QR gets hidden rather than offering a share
    /// option that can't actually reach the guest's phone.
    public var cameraIsSelfHostedAP: Bool {
        cameraIPText.hasPrefix("192.168.1.")
    }

    // MARK: - Home / event picker

    /// Leaves the splash screen for the event list.
    public func enterEventPicker() {
        guard step == .home else { return }
        step = .eventPicker
    }

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

    /// Attendant backs out of camera-connect to switch events — tears down
    /// any in-flight connect attempt so a stray transport doesn't linger.
    public func backToEventPicker() {
        eventConsumer?.cancel()
        eventConsumer = nil
        let staleTransport = transport
        transport = nil
        camera = nil
        Task { await staleTransport?.disconnect() }
        liveViewImage = nil
        cameraBatteryLevel = nil
        lastError = nil
        connectionMessage = "Enter the camera's IP and connect"
        step = .eventPicker
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
            cameraBatteryLevel = nil
        default:
            break
        }
    }

    private func startRemoteModeAndLiveView() async {
        guard let camera else { return }
        do {
            try await camera.enterRemoteMode()
            await camera.setBatterySink { [weak self] level in
                Task { @MainActor in self?.cameraBatteryLevel = level }
            }
            let frames = try await camera.startLiveView()
            liveViewConsumer?.cancel()
            liveViewConsumer = Task { [weak self] in
                for await jpeg in frames {
                    guard let self else { return }
                    if let image = UIImage(data: jpeg) {
                        await MainActor.run {
                            self.liveViewImage = image
                            if self.isRecordingFrames {
                                self.recordedFrames.append(jpeg)
                            }
                        }
                    }
                }
            }
            step = .attract
        } catch {
            lastError = "Remote mode / live view failed: \(error)"
        }
    }

    // MARK: - Guest flow

    /// `stripShotCount`/`layout` are the guest's choice at the attract
    /// screen — nil count means a plain single photo; a number picks one of
    /// the event's offered strip counts, and `layout` picks one of the
    /// offered layouts (config.strip.shotCounts/layouts, e.g. 3-shot and
    /// 4-shot, vertical and grid, all offered side by side). The event
    /// config only controls which combinations are *offered*, not which one
    /// every guest is forced into. Doesn't start the countdown directly —
    /// moves to a "Touch to Shoot" screen first so the guest has a moment to
    /// pose instead of the countdown firing the instant they pick a mode.
    public func tapToStart(stripShotCount: Int? = nil, layout: EventConfig.StripOptions.Layout = .vertical) {
        guard step == .attract else { return }
        returnToAttractTask?.cancel()
        EventStorage.shared.recordGuestSession(eventId: config.eventId)
        sessionShotCount = stripShotCount.map { max(2, $0) } ?? 1
        sessionLayout = layout
        sessionAnimatedStyle = nil
        step = .readyToShoot
    }

    /// Boomerang/GIF variant of tapToStart — records live-view frames
    /// instead of firing the shutter (see AnimatedCapture for why).
    public func tapToStartAnimated(_ style: AnimatedStyle) {
        guard step == .attract else { return }
        returnToAttractTask?.cancel()
        EventStorage.shared.recordGuestSession(eventId: config.eventId)
        sessionAnimatedStyle = style
        step = .readyToShoot
    }

    /// The actual "go" — called from the Touch to Shoot screen.
    public func confirmReadyToShoot() {
        guard step == .readyToShoot else { return }
        returnToAttractTask?.cancel()
        beginCountdown()
    }

    /// Manual bail from Touch to Shoot back to attract — otherwise the only
    /// way out is touching to shoot or waiting for the 15s auto-return.
    public func cancelReadyToShoot() {
        guard step == .readyToShoot else { return }
        returnToAttractTask?.cancel()
        step = .attract
    }

    /// Kicks off `sessionShotCount` shots in sequence (1 for a normal photo,
    /// several for a strip). Used by both tapToStart() and retake() — a
    /// retake redoes the whole sequence with the same layout the guest
    /// originally chose, matching the pre-strip retake semantics of "start
    /// over" 1:1.
    private func beginCountdown() {
        Task { await captureSequence() }
    }

    private func captureSequence() async {
        if let style = sessionAnimatedStyle {
            await recordAnimatedCapture(style: style)
            return
        }
        let totalShots = sessionShotCount
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

    /// Boomerang/GIF path: countdown, then ~2.5s of live-view frames into
    /// the buffer, encoded off-main into a looping GIF (filter applied per
    /// frame; overlay/Polaroid skipped — static-print concepts). Saved as
    /// .gif so Review/Share can tell it apart from stills by extension.
    private func recordAnimatedCapture(style: AnimatedStyle) async {
        let total = max(1, config.countdownSeconds)
        for remaining in stride(from: total, through: 1, by: -1) {
            step = .countdown(remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        recordedFrames = []
        isRecordingFrames = true
        step = .recording
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        isRecordingFrames = false
        let frames = recordedFrames
        recordedFrames = []

        guard !frames.isEmpty else {
            // Live view stalled the whole window (dead connection most
            // likely) — same guest-facing outcome as a failed capture.
            lastError = "Couldn't record — try again"
            step = .attract
            return
        }

        let currentFilter = selectedFilter
        let gifData = await Task.detached(priority: .userInitiated) {
            AnimatedCapture.encodeGIF(frames: frames, style: style, filter: currentFilter)
        }.value

        guard let gifData else {
            lastError = "Couldn't create the \(style.displayName) — try again"
            step = .attract
            return
        }
        do {
            let url = try EventStorage.shared.savePhoto(gifData, eventId: config.eventId, fileExtension: "gif")
            step = .review(url)
        } catch {
            lastError = "Save failed: \(error)"
            step = .attract
        }
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
        } catch is TimeoutError {
            // A genuine hang — the connection itself is dead (that's what
            // caused the hang in the first place). Disconnecting unblocks the
            // leaked read (NWConnection.cancel() completes pending receives
            // with an error) and self-heals by reconnecting with the same
            // IP, rather than leaving the booth silently wedged until an
            // attendant notices and manually hits Connect again.
            lastError = "Capture failed: connection timed out"
            step = .attract
            await transport?.disconnect()
            step = .connecting
            connectionMessage = "Connection lost — reconnecting…"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            connectCamera()
            return nil
        } catch {
            // The camera responded — it just couldn't complete the shot,
            // most often a failed autofocus lock rejecting the shutter
            // release (EOSError.badResponse). The connection is fine, so
            // don't tear it down — that was the actual bug: any capture
            // error, AF failures included, was triggering a full
            // disconnect/reconnect meant only for a dead connection.
            lastError = "Couldn't take the photo — try again"
            step = .attract
            return nil
        }
    }

    /// Composites multiple shots into a strip (or passes a single shot
    /// through unchanged), burns in the overlay if configured, and saves —
    /// same end state (`.review(url)`) as the original single-shot path.
    /// The actual pixel work runs off the main actor: decoding and drawing
    /// several full-resolution camera JPEGs into one canvas is real CPU work,
    /// and running it synchronously here (BoothViewModel is @MainActor)
    /// blocked the UI thread long enough to risk a watchdog termination —
    /// the crash seen right after the last shot in a strip.
    private func finishCapture(shots: [Data]) {
        guard let firstShot = shots.first else { return }
        let currentConfig = config
        let currentLayout = sessionLayout
        let currentFilter = selectedFilter
        Task {
            let branded = await Task.detached(priority: .userInitiated) {
                var composited: Data
                if shots.count > 1 {
                    composited = PhotoCompositor.compositeStrip(shots, layout: currentLayout) ?? firstShot
                } else {
                    composited = firstShot
                }
                // Filter before overlay/frame so the brand overlay and the
                // Polaroid border stay unfiltered — only the photo content
                // gets the look.
                composited = currentFilter.apply(to: composited)
                if currentConfig.squareCrop {
                    composited = PhotoCompositor.applySquareCrop(to: composited)
                }
                let branded = PhotoCompositor.applyOverlay(to: composited, config: currentConfig)
                return PhotoCompositor.addPolaroidFrame(to: branded)
            }.value
            do {
                let url = try EventStorage.shared.savePhoto(branded, eventId: currentConfig.eventId)
                step = .review(url)
            } catch {
                lastError = "Save failed: \(error)"
                step = .attract
            }
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
        selectedFilter = .none
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

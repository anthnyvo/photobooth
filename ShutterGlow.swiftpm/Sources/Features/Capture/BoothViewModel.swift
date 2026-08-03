import Foundation
import SwiftUI
import CameraKit
import BoothStorage

/// Guest-facing flow state. Distinct from ShutterGlow's diagnostic
/// SpikeViewModel — this one drives the actual booth experience, reusing the
/// same CameraKit transport/protocol layer proven out in Phase 0.
public enum BoothStep: Equatable {
    case login
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
    @Published public private(set) var step: BoothStep
    @Published public private(set) var config: EventConfig
    @Published public private(set) var isSyncing = false
    @Published public private(set) var syncError: String?
    /// Frames and the prop overlay live in their own ObservableObject so
    /// per-frame churn doesn't invalidate every view observing this model —
    /// see LiveViewFeed. These passthroughs keep the model's internal code
    /// (and the couple of non-per-frame readers) unchanged.
    public let liveFeed = LiveViewFeed()
    public var liveViewImage: UIImage? {
        get { liveFeed.image }
        set { liveFeed.image = newValue }
    }
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
    /// Guest's face-prop pick (shades, dog ears, ...) — anchored to detected
    /// faces and burned into the file in finishCapture (or per frame for
    /// Boomerang/GIF). Resets per guest, same as selectedFilter.
    @Published public var selectedProp: PhotoProp = .none
    /// Guest's decorative-sticker pick (a filename from config.stickers), or
    /// nil for none. Composited full-frame in finishCapture. Resets per guest.
    @Published public var selectedSticker: String?
    /// True once this guest has filled (or skipped) the data-capture form, so
    /// the share screen doesn't re-prompt them. Resets per guest.
    @Published public var leadCollectedThisSession = false
    /// Transparent props-only frame matching the live view's pixel aspect —
    /// rendered a few times a second by runLivePropOverlayLoop(). Stored on
    /// liveFeed (per-frame churn, same reasoning as liveViewImage).
    public private(set) var livePropOverlay: UIImage? {
        get { liveFeed.propOverlay }
        set { liveFeed.propOverlay = newValue }
    }
    /// Behind-the-scenes timelapse of the last strip session — the frantic
    /// pose scramble between shots, sampled from live view and encoded as a
    /// fast GIF. Non-nil only after a timelapse-enabled strip completes;
    /// cleared when the guest's session ends.
    @Published public private(set) var timelapseURL: URL?

    /// Attendant's camera-brand pick on the connect screen — persisted so
    /// one booth setup survives relaunches. Only Canon is hardware-verified;
    /// Sony (both variants) is under active test (see CameraBrand).
    @Published public var selectedBrand: CameraBrand = CameraBrand.loadSaved() {
        didSet { selectedBrand.save() }
    }

    /// USB (ICCTransport) or Wi-Fi (PTPIPTransport), chosen at connect time by
    /// whether a camera is actually on the cable — see bringUpCanon.
    private var transport: (any PTPTransport)?

    /// True once ICDeviceBrowser has seen a camera on USB during a connect
    /// attempt. Drives the USB-or-Wi-Fi decision, and the IP field's
    /// visibility: an operator on a cable should never be shown an IP box.
    @Published public private(set) var wifiFallbackVisible = false
    private var usbCameraSeen = false

    /// Whether to show the camera IP field at all.
    ///
    /// Sony is Wi-Fi only, so it always needs one. USB Webcam is a cable and
    /// never does. Canon hides it until a USB probe has actually failed — the
    /// common case is now "plug the cable in and tap Connect", and putting a
    /// network field in front of that invites an operator to fill it in when
    /// nothing needs it.
    public var showsIPField: Bool {
        switch selectedBrand {
        case .usbWebcam: false
        case .sony: true
        case .canonEOS: wifiFallbackVisible
        }
    }
    private var camera: (any TetheredCamera)?
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
    /// Raw JPEG of the newest live-view frame, kept alongside the decoded
    /// UIImage so face scans (prop overlay, smile shutter) work straight
    /// off camera bytes instead of re-encoding the UIImage every pass.
    private var latestLiveFrameJPEG: Data?

    public init(config: EventConfig = EventStorage.shared.loadCurrentOrDefault()) {
        self.config = config
        self.step = SupabaseAuth.shared.currentSession() != nil ? .home : .login
    }

    public func reloadConfig() {
        config = EventStorage.shared.loadCurrentOrDefault()
    }

    // MARK: - Auth / sync

    public var signedInEmail: String? {
        SupabaseAuth.shared.currentSession()?.email
    }

    public func signIn(email: String, password: String) async {
        lastError = nil
        do {
            _ = try await SupabaseAuth.shared.signIn(email: email, password: password)
            step = .home
            await syncRemoteEvents()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Sign in failed"
        }
    }

    public func signOut() {
        SupabaseAuth.shared.signOut()
        step = .login
    }

    /// Pulls this operator's events from the shared backend and mirrors them
    /// into local storage. Best-effort: a failure (offline, expired session)
    /// just leaves whatever's already cached in place rather than surfacing
    /// as a hard error — the picker still works either way.
    @discardableResult
    public func syncRemoteEvents() async -> Bool {
        guard SupabaseAuth.shared.currentSession() != nil else { return false }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let count = try await RemoteSync.syncEvents()
            DiagnosticLog.shared.log(.sync, "sync ok, \(count) events")
            return true
        } catch let error as RemoteSync.SyncError {
            // Say which failure it was. An expired session and a dead venue
            // Wi-Fi need completely different responses from the attendant,
            // and the old single string made them indistinguishable.
            syncError = error.attendantMessage
            DiagnosticLog.shared.log(.sync, "sync failed: \(error)")
            return false
        } catch {
            syncError = "Couldn't sync. Showing cached events."
            DiagnosticLog.shared.log(.sync, "sync failed (unexpected): \(error)")
            return false
        }
    }

    /// Whether QR sharing can plausibly work: the QR encodes a URL to THIS
    /// iPad's LocalPhotoServer (built from its own Wi-Fi IP), so what matters
    /// is that the iPad has a real Wi-Fi LAN address — not the camera's IP.
    ///
    /// The previous check keyed off the CAMERA's IP being 192.168.1.x, on the
    /// theory that that's the camera's private-AP default. But 192.168.1.x is
    /// also the single most common consumer/venue router subnet, so it hid QR
    /// at the majority of real venues where sharing would have worked fine —
    /// checking the wrong device entirely. If the iPad has no en0 IPv4 (no
    /// Wi-Fi, or joined the camera's bare AP with no reachable clients), the
    /// server URL is useless and QR is correctly hidden.
    public var qrSharingAvailable: Bool {
        NetworkInfo.wifiIPv4Address() != nil
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
        liveViewConsumer?.cancel()
        liveViewConsumer = nil
        // Disconnect the camera itself, not just the transport. Nilling the
        // camera without disconnecting leaked a live AVCaptureSession on the
        // USB path — it kept running and holding the one external camera, so
        // reconnecting later came up with no live view because the new
        // session couldn't claim a device the orphaned one still owned.
        let staleCamera = camera
        let staleTransport = transport
        camera = nil
        transport = nil
        Task {
            await staleCamera?.disconnect()
            await staleTransport?.disconnect()
        }
        liveViewImage = nil
        cameraBatteryLevel = nil
        lastError = nil
        connectionMessage = "Enter the camera's IP and connect"
        step = .eventPicker
    }

    // MARK: - Connection (attendant setup step)

    /// True while a teardown+bring-up is mid-flight. A second tap of Connect
    /// before the first finished used to spawn a second bring-up in parallel,
    /// which on USB meant two AVCaptureSessions fighting over the one external
    /// camera — the same "came up black" failure, just triggered by an
    /// impatient double-tap instead of a stale session.
    private var connectInFlight = false

    public func connectCamera() {
        guard !connectInFlight else { return }
        connectInFlight = true
        lastError = nil
        connectionMessage = "Connecting to \(cameraIPText)…"

        // A re-tap (typo'd IP, impatience), a back-out/return, or the
        // capture-timeout self-heal all route through here, so the previous
        // attempt must be torn down first. Crucially, WAIT for that teardown
        // to finish before bringing up the new camera. The old code fired the
        // disconnects off in detached Tasks and immediately started the new
        // session/socket — a race that on the USB path let the previous
        // AVCaptureSession still hold the one external camera when the new
        // one called startRunning(), so the reconnect came up black.
        eventConsumer?.cancel()
        eventConsumer = nil
        liveViewConsumer?.cancel()
        liveViewConsumer = nil
        let staleCamera = camera
        let staleTransport = transport
        camera = nil
        transport = nil

        let brand = selectedBrand
        let host = cameraIPText
        Task { [weak self] in
            await staleCamera?.disconnect()
            await staleTransport?.disconnect()
            self?.bringUpCamera(brand: brand, host: host)
            self?.connectInFlight = false
        }
    }

    /// Second half of connectCamera, run only after the previous camera and
    /// transport have fully disconnected. Kept separate so that ordering is
    /// enforced by a single await chain rather than hoped for across detached
    /// Tasks.
    private func bringUpCamera(brand: CameraBrand, host: String) {
        // Sony speaks HTTP (Camera Remote API), not PTP/IP — no transport
        // handshake to wait on, so it jumps straight to the shared
        // remote-mode + live-view bring-up.
        if brand == .sony {
            guard let cam = SonyCamera(host: host) else {
                lastError = "Couldn't connect — check the camera's IP address"
                DiagnosticLog.shared.log(.camera, "connect failed: bad/unreachable IP")
                connectionMessage = "Enter the camera's IP and connect"
                return
            }
            camera = cam
            Task {
                await startRemoteModeAndLiveView()
            }
            return
        }

        // USB webcam mode is a wired UVC video feed, not a network
        // protocol — no IP, no transport handshake, same shared
        // remote-mode + live-view bring-up as Sony's HTTP path above.
        if brand == .usbWebcam {
            camera = UVCWebcamCamera()
            Task {
                await startRemoteModeAndLiveView()
            }
            return
        }

        Task { [weak self] in await self?.bringUpCanon(host: host) }
    }

    /// Canon over USB when a camera is on the cable, Wi-Fi when there isn't.
    ///
    /// USB is preferred and the operator is never asked to choose. It needs no
    /// AP, no pairing and no IP address, and it measured faster than Wi-Fi on
    /// both live view (30-36 fps vs 14) and capture (1.94s vs 2.79s) — see
    /// docs/PHASE0.md. Making that a setting would just be a way to get it
    /// wrong at a venue.
    private func bringUpCanon(host: String) async {
        usbCameraSeen = false
        wifiFallbackVisible = false
        connectionMessage = "Looking for a camera on USB…"

        let usb = ICCTransport()
        transport = usb
        camera = EOSCamera(transport: usb)
        // Wired before start() so the browser cannot report a device into a
        // stream nobody is reading yet. handle() takes it from .ready onwards,
        // so a USB camera brings itself all the way up with no further work.
        eventConsumer = Task { [weak self] in
            for await event in usb.events {
                await self?.handle(event)
            }
        }
        usb.start()

        // Probe on .deviceFound, not .ready: ImageCaptureCore indexes the
        // card's whole catalog before firing ready (~9s on a full card), and
        // waiting that long before offering the Wi-Fi box would feel broken.
        // deviceFound is the honest "something is on the cable" signal.
        for _ in 0..<12 {
            if usbCameraSeen { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Nothing on the cable. Drop the browser before opening a PTP/IP
        // session — leaving it scanning would have two transports live at once
        // and a stale ICCTransport still holding its delegate callbacks.
        eventConsumer?.cancel()
        eventConsumer = nil
        usb.stop()
        camera = nil
        transport = nil

        wifiFallbackVisible = true
        connectionMessage = "No camera on USB — connecting to \(host)…"

        let wifiTransport = PTPIPTransport(host: host)
        transport = wifiTransport
        camera = EOSCamera(transport: wifiTransport)

        eventConsumer = Task { [weak self] in
            for await event in wifiTransport.events {
                await self?.handle(event)
            }
        }

        do {
            try await wifiTransport.connect()
        } catch {
            lastError = "Connect failed: \(error)"
            DiagnosticLog.shared.log(.camera, "connect failed: \(error)")
            connectionMessage = "No camera found on USB, and the Wi-Fi connection failed. Either plug the camera in with a USB-C cable, or check it is in Remote control (EOS Utility) mode and the IP is right."
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .deviceFound(let name):
            usbCameraSeen = true
            connectionMessage = "Found \(name) — starting session…"
        case .ready:
            connectionMessage = "Camera ready — starting live view…"
            await startRemoteModeAndLiveView()
        case .deviceRemoved:
            lastError = "Camera disconnected"
            DiagnosticLog.shared.log(.camera, "camera disconnected mid-session")
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
            // Detached on purpose: a plain Task{} here inherits the main
            // actor, which put every frame's JPEG decode on the main thread
            // — and UIImage defers the actual bitmap decompress to first
            // render, landing that on the main thread too. Decoding AND
            // rasterizing (preparingForDisplay) off-main turns each frame's
            // main-thread cost into a pointer swap + composited blit, which
            // is both the smoothness fix and an effective frame-rate raise:
            // the stream buffers only the newest frame, so a slow consumer
            // was silently dropping frames the camera had already delivered.
            liveViewConsumer = Task.detached(priority: .userInitiated) { [weak self] in
                for await jpeg in frames {
                    guard let self else { return }
                    guard let raw = UIImage(data: jpeg) else { continue }
                    let image = raw.preparingForDisplay() ?? raw
                    await MainActor.run {
                        self.liveFeed.image = image
                        self.latestLiveFrameJPEG = jpeg
                        if self.isRecordingFrames {
                            self.recordedFrames.append(jpeg)
                        }
                    }
                }
            }
            step = .attract
        } catch {
            lastError = "Remote mode / live view failed: \(error)"
            DiagnosticLog.shared.log(.camera, "live view failed: \(error)")
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
        recordGuestSession()
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
        recordGuestSession()
        sessionAnimatedStyle = style
        step = .readyToShoot
    }

    /// Local counter (attendant status panel, always works offline) plus a
    /// best-effort backend log for the dashboard's Insights page — see
    /// RemoteSync.recordRemoteGuestSession's doc comment for why that half
    /// is fire-and-forget from a detached Task.
    private func recordGuestSession() {
        EventStorage.shared.recordGuestSession(eventId: config.eventId)
        let eventId = config.eventId
        Task.detached(priority: .background) {
            await RemoteSync.recordRemoteGuestSession(eventId: eventId)
        }
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
        // Re-entry guard. Both triggers race in practice: the smile-shutter
        // poll can fire in the same beat as the guest's tap (both pass the
        // .readyToShoot check before the Task below flips step), and Retake
        // can be double-tapped. Two concurrent captureSequences interleave
        // countdowns and fire the shutter twice.
        guard !captureInFlight else { return }
        captureInFlight = true
        Task {
            defer { captureInFlight = false }
            await captureSequence()
        }
    }

    private var captureInFlight = false

    private func captureSequence() async {
        if let style = sessionAnimatedStyle {
            await recordAnimatedCapture(style: style)
            return
        }
        let totalShots = sessionShotCount

        // Strip timelapse: sample the live feed ~2x/sec for the WHOLE
        // sequence — countdowns, the scramble between shots, the flashes —
        // and encode it after the strip lands. Capped so a stalled sequence
        // can't grow the buffer unbounded.
        timelapseURL = nil
        var timelapseFrames: [Data] = []
        var timelapseSampler: Task<Void, Never>?
        if totalShots > 1 && config.timelapseEnabled {
            timelapseSampler = Task { [weak self] in
                while !Task.isCancelled {
                    // Raw camera bytes straight into the buffer. The old
                    // path re-encoded the displayed UIImage to JPEG on the
                    // main thread twice a second for the whole sequence —
                    // right through the countdowns and shutter round-trips
                    // where the main thread is busiest.
                    if let self, let jpeg = self.latestLiveFrameJPEG {
                        timelapseFrames.append(jpeg)
                        if timelapseFrames.count >= 140 { return }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        defer { timelapseSampler?.cancel() }

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
        // Let the timelapse run ~2.5s past the last flash — the group's
        // reaction after the final shot is usually the best frame of the
        // whole thing.
        if timelapseSampler != nil {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        timelapseSampler?.cancel()
        finishCapture(shots: shots)

        // Encode off-main after the strip is on its way — a failed encode
        // just means no timelapse dial appears, never a failed session.
        if timelapseFrames.count >= 6 {
            let frames = timelapseFrames
            let eventId = config.eventId
            let gifData = await Task.detached(priority: .utility) {
                AnimatedCapture.encodeGIF(frames: frames, style: .gif, filter: .none, frameDelay: 0.09)
            }.value
            if let gifData,
               let url = try? EventStorage.shared.savePhoto(gifData, eventId: eventId, fileExtension: "gif") {
                timelapseURL = url
            }
        }
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
            DiagnosticLog.shared.log(.capture, "record failed")
            step = .attract
            return
        }

        let currentFilter = selectedFilter
        let currentProp = selectedProp
        let gifData = await Task.detached(priority: .userInitiated) {
            AnimatedCapture.encodeGIF(frames: frames, style: style, filter: currentFilter, prop: currentProp)
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
            DiagnosticLog.shared.log(.capture, "save failed: \(error)")
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

        guard let camera else {
            // Every other early-return in this function sets lastError and
            // moves off the countdown/capturing step; this one didn't,
            // which left step stuck wherever the countdown loop above left
            // it (e.g. .countdown(1)) with nothing to recover it.
            lastError = "No camera connected"
            step = .connecting
            return nil
        }
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
            DiagnosticLog.shared.log(.capture, "capture timed out")
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
        let currentProp = selectedProp
        let currentSticker = selectedSticker
        Task {
            let branded = await Task.detached(priority: .userInitiated) {
                // Per shot, BEFORE compositing: background replace first (the
                // person is largest/cleanest in the raw frame, best for
                // segmentation), then face props anchor onto that, then the
                // colour filter. Filtering per shot keeps the strip's white
                // gutters and the Polaroid stock clean, not tinted.
                let processedShots = shots.map { shot in
                    var processed = shot
                    processed = PhotoCompositor.replaceBackground(to: processed, config: currentConfig)
                    if currentProp != .none {
                        processed = FacePropRenderer.apply(currentProp, to: processed)
                    }
                    processed = currentFilter.apply(to: processed)
                    // Square crop is per SHOT, before compositing. Cropping
                    // the composited strip instead (the old order) squared
                    // off the whole strip: a 4-shot vertical strip is ~3x
                    // taller than wide, so the centered square kept only the
                    // middle ~2 frames — the guest shot 4 photos and got a
                    // print showing 2.
                    if currentConfig.squareCrop {
                        processed = PhotoCompositor.applySquareCrop(to: processed)
                    }
                    return processed
                }
                let firstProcessed = processedShots.first ?? firstShot

                var composited: Data
                if processedShots.count > 1 {
                    composited = PhotoCompositor.compositeStrip(processedShots, layout: currentLayout) ?? firstProcessed
                } else {
                    composited = firstProcessed
                }
                // Event overlay, then the guest's chosen sticker, then the
                // Polaroid frame last so the border wraps everything.
                var branded = PhotoCompositor.applyOverlay(to: composited, config: currentConfig)
                branded = PhotoCompositor.applySticker(currentSticker, to: branded, config: currentConfig)
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
        // ReviewView's own auto-return timer (scheduled when it appeared)
        // is still ticking — a strip retake's countdown+capture+timelapse
        // sequence can run past its 20s window, and without this the timer
        // would fire mid-sequence and force step back to .attract while a
        // capture is in flight.
        returnToAttractTask?.cancel()
        beginCountdown()
    }

    public func accept() {
        guard case .review(let url) = step else { return }
        returnToAttractTask?.cancel()
        step = .sharing(url)
    }

    /// Records an opt-in lead from the data-capture form (stored locally per
    /// event; never auto-uploaded) and marks this guest handled either way.
    /// An empty lead (guest skipped) just sets the flag.
    public func submitLead(_ lead: EventStorage.GuestLead?) {
        if let lead, !(lead.name.isEmpty && lead.email.isEmpty && lead.phone.isEmpty) {
            EventStorage.shared.appendLead(lead, eventId: config.eventId)
        }
        leadCollectedThisSession = true
    }

    /// Called from the share screen once the guest is done (or after a
    /// timeout) — back to idle, auto-return after a short delay handled by
    /// the view itself calling this on a timer.
    public func returnToAttract() {
        liveViewImage = liveViewImage // keep last frame visible during transition
        selectedFilter = .none
        selectedProp = .none
        selectedSticker = nil
        leadCollectedThisSession = false
        livePropOverlay = nil
        timelapseURL = nil
        step = .attract
    }

    // MARK: - Live prop preview

    /// Views showing live view run this for their lifetime (`.task {}` —
    /// cancelled automatically on disappear). ~11 scans/sec against the raw
    /// camera JPEG (no re-encode): Vision landmark detection at live-view
    /// resolution is a few ms on modern iPads, so props visibly stick to
    /// faces instead of trailing them. The overlay is nil whenever no prop
    /// is picked, props are disabled, or no face is currently detectable.
    public func runLivePropOverlayLoop() async {
        while !Task.isCancelled {
            await refreshLivePropOverlay()
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    }

    /// Last frame a prop scan actually ran against — skips redundant Vision
    /// passes when live view is paused (mid-capture) or slow, which was
    /// burning CPU at 11 scans/sec against the same stale frame during the
    /// exact window the shutter round-trip needs it.
    private var lastPropScannedFrame: Data?

    /// Temporal smoothing state across live prop scans — props glide with
    /// the face instead of jittering, and survive brief detection misses.
    private var propSmoother = FaceSmoother()

    /// Three screens (attract, ready-to-shoot, capture) each run the loop
    /// for their own lifetime, and step-transition crossfades keep two
    /// alive at once — without this, overlapping refreshes double-scan and
    /// clobber each other's smoother write-back.
    private var propScanInFlight = false

    private func refreshLivePropOverlay() async {
        guard !propScanInFlight else { return }
        guard config.ai.props, selectedProp != .none,
              let jpeg = latestLiveFrameJPEG else {
            livePropOverlay = nil
            lastPropScannedFrame = nil
            propSmoother.reset()
            return
        }
        // The flash/shutter window gets the CPU to itself — the overlay
        // just holds its last render for that beat.
        guard step != .capturing else { return }
        // No new frame since the last scan (live view paused or between
        // polls) → nothing to recompute.
        guard jpeg != lastPropScannedFrame else { return }
        lastPropScannedFrame = jpeg

        let prop = selectedProp
        let smoother = propSmoother
        propScanInFlight = true
        defer { propScanInFlight = false }
        let result = await Task.detached(priority: .utility) {
            FacePropRenderer.liveScan(prop, frameData: jpeg, smoother: smoother)
        }.value
        // The loop awaits each scan before starting the next, so writing
        // the smoother back can't race a concurrent scan.
        propSmoother = result.smoother
        // Prop may have changed while the scan ran — drop a stale render
        // rather than flashing the previous prop's shapes.
        guard selectedProp == prop else { return }
        livePropOverlay = result.overlay
    }

    // MARK: - Live face analysis (smile shutter / face count)

    public struct LiveFaceReading: Sendable {
        public let faceCount: Int
        public let smiling: Bool
    }

    /// One face pass over the current live-view frame, off the main actor —
    /// polled by ReadyToShootView while the smile shutter is enabled. Zero
    /// faces when live view hasn't produced a frame yet. Uses the raw
    /// camera JPEG (Sendable Data across the actor hop; no re-encode).
    /// Smile comes from Vision lip geometry — see FaceVision.
    public func analyzeLiveViewFaces() async -> LiveFaceReading {
        guard let jpeg = latestLiveFrameJPEG else {
            return LiveFaceReading(faceCount: 0, smiling: false)
        }
        return await Task.detached(priority: .utility) {
            guard let cgImage = FaceVision.detectionImage(from: jpeg) else {
                return LiveFaceReading(faceCount: 0, smiling: false)
            }
            let faces = FaceVision.detectFaces(in: cgImage, accuracy: .live)
            return LiveFaceReading(
                faceCount: faces.count,
                smiling: faces.contains(where: \.hasSmile)
            )
        }.value
    }

    public func scheduleAutoReturn(after seconds: TimeInterval = 20) {
        returnToAttractTask?.cancel()
        returnToAttractTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { returnToAttract() }
        }
    }

    /// Pauses the idle auto-return — called while a guest is actively
    /// mid-share (QR sheet open, composing an email, print dialog up) so the
    /// 20s timer can't tear the screen down and discard their in-progress
    /// action. The caller re-arms it with scheduleAutoReturn() on dismiss.
    public func cancelAutoReturn() {
        returnToAttractTask?.cancel()
        returnToAttractTask = nil
    }
}

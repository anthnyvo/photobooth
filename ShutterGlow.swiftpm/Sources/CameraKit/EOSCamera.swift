import Foundation

public enum EOSError: Error {
    case badResponse(operation: String, code: UInt16?)
    case liveViewNotStreaming
    case captureTimeout
}

public struct LiveViewStats: Sendable {
    public var framesReceived: Int = 0
    public var emptyPolls: Int = 0
    public var fps: Double = 0
    /// nil until the first real frame decodes — do not default this to a
    /// value, or "no frames yet" silently reads as "structured: yes".
    public var usedStructuredFraming: Bool?
}

/// Canon EOS remote-control state machine over any PTP transport.
///
/// Connect sequence (per libgphoto2's ptp2 camlib):
///   SetRemoteMode(1) -> SetEventMode(1) -> event poll loop
/// Live view:
///   EVFMode=1, EVFOutputDevice=PC -> poll GetViewFinderData(0x00200000,0,0)
/// Capture:
///   RemoteRelease (0x910F); fall back to RemoteReleaseOn/Off half+full pair.
public actor EOSCamera {

    public enum State: Sendable, Equatable {
        case idle, connecting, connected, liveView, failed(String)
    }

    private let transport: any PTPTransport
    public private(set) var state: State = .idle
    private var eventLoopTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    public private(set) var liveViewStats = LiveViewStats()
    /// Raw value from the last PropValueChanged event carrying
    /// CanonProp.batteryLevel — nil until (if) the body ever sends one.
    /// Unverified encoding (see CanonProp.batteryLevel) — best-effort.
    public private(set) var batteryLevel: UInt32?

    /// Diagnostic log lines, mirrored to the spike UI.
    private var logSink: (@Sendable (String) -> Void)?
    /// Fired whenever a fresh battery reading arrives, so BoothViewModel can
    /// mirror it onto a @Published property without polling the actor.
    private var batterySink: (@Sendable (UInt32) -> Void)?

    public init(transport: any PTPTransport) {
        self.transport = transport
    }

    public func setLogSink(_ sink: @escaping @Sendable (String) -> Void) {
        logSink = sink
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        batterySink = sink
    }

    private func log(_ message: String) {
        logSink?("[EOS] \(message)")
    }

    // MARK: - Connect

    /// Call once the transport reports `.ready`.
    public func enterRemoteMode() async throws {
        state = .connecting
        do {
            try await expectOK("SetRemoteMode",
                await transport.send(code: CanonOp.setRemoteMode, parameters: [1]))
            try await expectOK("SetEventMode",
                await transport.send(code: CanonOp.setEventMode, parameters: [1]))
            startEventLoop()
            // TEMPORARILY DISABLED for a diagnostic test: AF has been
            // blocked camera-wide (remote AND physical shutter both) for
            // the entire remote session on every prior build, and every
            // theory involving EVFOutputDevice or the RemoteReleaseOn AF
            // parameter has been ruled out on hardware. The only other
            // thing enterRemoteMode() changes from the body's own defaults
            // is this property (default read as 2/Card; we were forcing 4/
            // Host). Leaving it untouched to isolate whether this is the
            // actual variable before committing to redesigning capture
            // retrieval around card storage.
            // try await setProperty(CanonProp.captureDestination,
            //                       CanonProp.captureDestinationHost,
            //                       name: "CaptureDestination=Host")
            log("CaptureDestination left at camera default (diagnostic test — see comment above)")
            state = .connected
            log("remote mode active")
        } catch {
            state = .failed("enterRemoteMode: \(error)")
            throw error
        }
    }

    /// Canon bodies require the host to keep draining events; a stalled event
    /// queue eventually wedges the camera. Poll continuously while connected.
    private func startEventLoop() {
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let result = try await self.transport.send(code: CanonOp.getEvent)
                    let records = CanonEventRecord.parse(result.payload)
                    for record in records {
                        // PropValueChanged (0xC189) is filtered from the
                        // general log (it fires constantly) except for the
                        // couple of props worth seeing ground truth for —
                        // Canon EOS has no synchronous "get current value"
                        // call; libgphoto2's own getdevicepropdesc is a pure
                        // cache lookup populated from exactly this event.
                        if record.type == CanonEvent.propValueChanged {
                            if record.payload.count >= 8 {
                                let propcode = record.payload.readLE(UInt32.self, at: 0)
                                if propcode == CanonProp.focusMode || propcode == CanonProp.captureDestination {
                                    let valueBytes = record.payload.dropFirst(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                                    await self.log(String(format: "prop 0x%04X = [%@]", propcode, valueBytes))
                                }
                                if propcode == CanonProp.batteryLevel, record.payload.count >= 8 {
                                    let value = record.payload.readLE(UInt32.self, at: 4)
                                    await self.recordBatteryLevel(value)
                                }
                            }
                            continue
                        }
                        await self.log(String(format: "event 0x%04X (%d bytes)", record.type, record.payload.count))
                    }
                } catch {
                    await self.log("event poll error: \(error)")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // Slower now that live view is running: GetEvent and
                // GetViewFinderData take turns on one shared connection, so
                // polling events this often was stealing most of live view's
                // bandwidth for no real benefit — event draining still
                // matters (keeps the body from wedging) but doesn't need to
                // be anywhere near this frequent.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Live view

    /// Starts polling live view frames. Frames arrive on the returned stream;
    /// fps and framing diagnostics accumulate in `liveViewStats`.
    public func startLiveView() async throws -> AsyncStream<Data> {
        // Matches the proven-working sequence (Canon PTP/IP reference
        // implementations): only EVFOutputDevice is set. There is no
        // separate "EVFMode" property in that sequence — the extra
        // 0xD1B3 set this code used to send has no confirmed purpose and
        // was a likely cause of the camera never actually starting the
        // stream (GetViewFinderData returned 0 bytes / OK indefinitely).
        // EVFOutputDevice was ruled out as the cause of the AF-blocked-while-
        // connected bug: 0 (off), 2 (PC-only), and 3 (cameraAndHost) all
        // behaved identically on hardware. Real cause was the second
        // RemoteReleaseOn parameter forcing an AF attempt this manual-focus
        // lens can never complete (see triggerShutter). Back to 3 so the
        // camera's own screen shows live view too, for guest-facing framing.
        try await setProperty(CanonProp.evfOutputDevice, 3, name: "EVFOutputDevice=cameraAndHost")
        // Settle time: the sensor/imaging pipeline needs a moment to actually
        // start streaming after this property lands. Polling immediately (and
        // then hammering the body every ~50ms) is a documented way to keep a
        // Canon EOS body stuck reporting "not ready" indefinitely.
        try? await Task.sleep(nanoseconds: 500_000_000)
        state = .liveView
        liveViewStats = LiveViewStats()

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self,
            bufferingPolicy: .bufferingNewest(1))
        liveViewContinuation = continuation
        startLiveViewPolling()
        return stream
    }

    /// Stored so capture can fully tear down and later resume polling
    /// against the same stream the UI already subscribed to — calling
    /// startLiveView() again would hand back a stream nobody's listening to.
    private var liveViewContinuation: AsyncStream<Data>.Continuation?

    private func startLiveViewPolling() {
        liveViewTask?.cancel()
        liveViewTask = Task { [weak self] in
            var windowStart = ContinuousClock.now
            var windowFrames = 0
            var lastDiagLog = ContinuousClock.now.advanced(by: .seconds(-10))
            while !Task.isCancelled {
                guard let self, let continuation = await self.liveViewContinuation else { break }
                if await self.isCapturePaused {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                do {
                    let result = try await self.transport.send(
                        code: CanonOp.getViewFinderData,
                        parameters: [0x0020_0000, 0, 0])
                    switch LiveViewParser.extractJPEG(result.payload) {
                    case .frame(let jpeg, let structured):
                        continuation.yield(jpeg)
                        windowFrames += 1
                        await self.recordFrame(structured: structured)
                    case .noFrame:
                        await self.recordEmptyPoll()
                        // Throttled raw-payload dump — this is the actual
                        // Phase 0 evidence needed to fix the parser.
                        if lastDiagLog.duration(to: .now) > .seconds(2) {
                            lastDiagLog = .now
                            let payload = result.payload
                            let prefix = payload.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
                            await self.log("noFrame: payload \(payload.count) bytes, response code \(result.response.map { String(format: "0x%04X", $0.code) } ?? "none"), prefix [\(prefix)]")
                        }
                    }
                    // The 200ms fixed delay here was a defensive guess made
                    // while chasing what turned out to be an unrelated bug
                    // (a stray outData: Data() elsewhere skipping the data-
                    // phase read entirely). With that fixed, poll as fast as
                    // the camera/network allow — a tiny yield only, so the
                    // event loop still gets a turn on the shared connection.
                    try? await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    await self.log("live view poll error: \(error)")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // fps over a rolling 2s window — THE Phase 0 number.
                let elapsed = windowStart.duration(to: .now)
                if elapsed > .seconds(2) {
                    let seconds = Double(elapsed.components.seconds) +
                        Double(elapsed.components.attoseconds) / 1e18
                    await self.recordFPS(Double(windowFrames) / seconds)
                    windowStart = .now
                    windowFrames = 0
                }
            }
        }
    }

    public func stopLiveView() async throws {
        liveViewTask?.cancel()
        liveViewTask = nil
        liveViewContinuation?.finish()
        liveViewContinuation = nil
        try await setProperty(CanonProp.evfOutputDevice, 0, name: "EVFOutputDevice=off")
        state = .connected
    }

    private func recordBatteryLevel(_ value: UInt32) {
        batteryLevel = value
        batterySink?(value)
    }

    private func recordFrame(structured: Bool) {
        liveViewStats.framesReceived += 1
        liveViewStats.usedStructuredFraming = structured
    }
    private func recordEmptyPoll() { liveViewStats.emptyPolls += 1 }
    private func recordFPS(_ fps: Double) {
        liveViewStats.fps = fps
        let framing = liveViewStats.usedStructuredFraming.map { $0 ? "yes" : "no" } ?? "no frames decoded yet"
        log(String(format: "live view %.1f fps (structured framing: %@)", fps, framing))
    }

    // MARK: - Capture

    /// Set while a capture is in flight — the live view loop checks this and
    /// skips its own polling, leaving the room on the shared connection for
    /// the shutter/download calls. Deliberately does NOT touch
    /// EVFOutputDevice: a prior attempt fully tore the stream down
    /// (EVFOutputDevice=0) before capturing, on the theory that the camera's
    /// own EVF pipeline was contending for the shutter mechanism. That made
    /// no difference and is very likely backwards for a mirrorless body —
    /// the EOS R's Dual Pixel AF runs *through* the same continuous sensor
    /// stream live view uses, so turning it fully off may have killed the
    /// only pipeline AF depends on (matches hardware evidence: OLCInfoChanged,
    /// the focus-confirm event, never fired even once while EVF was down).
    private(set) var isCapturePaused = false

    /// Trigger the shutter and return the resulting full-resolution image.
    public func capturePhoto() async throws -> Data {
        eventLoopTask?.cancel()
        isCapturePaused = true
        defer {
            isCapturePaused = false
            startEventLoop()
        }
        try await triggerShutter()
        return try await transport.nextCapturedFile(timeout: 15)
    }

    private func triggerShutter() async throws {
        // Bare 0x910F (RemoteRelease) acks OK on EOS bodies but is a no-op —
        // it's a legacy PowerShot-era release, not implemented on EOS. EOS
        // bodies need the half-press (AF) + full-press pair instead,
        // matching libgphoto2's ptp2 camlib (camera_trigger_canon_eos_capture
        // in library.c) and EOS Utility's own sequence.
        //
        // Releasing half-press on a failed full-press (below) is real and
        // necessary — a leftover held half-press does make the body refuse
        // every future full-press with DeviceBusy — but wasn't the whole
        // story either. The actual finding: with the remote session active,
        // AF stopped working camera-wide — even the physical shutter button
        // couldn't focus until disconnecting. That rules out EVFOutputDevice
        // (tried 0, 2, and 3, all identical) and points at the second
        // RemoteReleaseOn parameter instead: per Canon's EDSDK semantics,
        // 0 = attempt AF, 1 = skip AF (instant press). This lens is a
        // manual-focus adapter with no AF motor — sending 0 makes the body's
        // firmware start an AF search that can never resolve, and it gets
        // stuck waiting forever, which is exactly what blocks every press
        // (remote or physical) afterward, not just ours. libgphoto2's
        // reference always sends 0 here, but its manual-focus special-case
        // never actually needed to change this param because the bodies it
        // was tested against still complete a (failed) AF cycle fast; this
        // adapter apparently never resolves the cycle at all.
        _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1])

        // param2=1 ("skip AF") on the half-press itself immediately failed
        // busy on hardware — half-press's whole point is normally to start
        // AF, so "half-press, don't AF" is likely a rejected/nonsensical
        // combination. Back to 0 (request AF) here; the non-AF flag stays
        // on the full-press below, which is where AF-confirm gating would
        // actually matter for a lens that can never send that confirm.
        try await expectOK("ReleaseOn(half)",
            await transport.send(code: CanonOp.remoteReleaseOn, parameters: [1, 0]))

        // From here on the half-press is ENGAGED on the body. Any throw
        // below this point — including the full-press send() itself
        // throwing on a network error, not just a bad response code, which
        // the explicit release at line ~353 never covered — must still
        // release it, or the body refuses every future press (remote or
        // physical) with DeviceBusy until power-cycled. halfPressReleased
        // tracks whether a path below already handled it explicitly, so
        // this defer doesn't double-send on the normal exit.
        var halfPressReleased = false
        defer {
            if !halfPressReleased {
                let transport = self.transport
                Task { _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1]) }
            }
        }

        // FocusMode==3 means manual focus, in which case libgphoto2 never
        // waits for AF confirmation at all — worth knowing which mode we're
        // actually in rather than relying on what a physical switch looked
        // like from outside. Also surfacing CaptureDestination here in case
        // it silently reverted from Host after the initial connect-time set.
        var sawOLCInfo = false
        for _ in 0..<5 {
            if let eventResult = try? await transport.send(code: CanonOp.getEvent) {
                for record in CanonEventRecord.parse(eventResult.payload) {
                    if record.type == CanonEvent.olcInfoChanged { sawOLCInfo = true }
                    if record.type == CanonEvent.propValueChanged, record.payload.count >= 8 {
                        let propcode = record.payload.readLE(UInt32.self, at: 0)
                        if propcode == CanonProp.focusMode || propcode == CanonProp.captureDestination {
                            let valueBytes = record.payload.dropFirst(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                            log(String(format: "  half-press wait: prop 0x%04X = [%@]", propcode, valueBytes))
                        }
                        continue
                    }
                    log(String(format: "  half-press wait: event 0x%04X (%d bytes)", record.type, record.payload.count))
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("half-press settle: OLCInfoChanged \(sawOLCInfo ? "seen" : "never seen")")

        let fullPress = try await transport.send(code: CanonOp.remoteReleaseOn, parameters: [2, 1])
        if let code = fullPress.response?.code, code != PTPResponseCode.ok {
            _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1])
            halfPressReleased = true
            log(String(format: "ReleaseOn(full) failed: 0x%04X — half-press released", code))
            throw EOSError.badResponse(operation: "ReleaseOn(full)", code: code)
        }

        try await expectOK("ReleaseOff(full)",
            await transport.send(code: CanonOp.remoteReleaseOff, parameters: [2]))
        try await expectOK("ReleaseOff(half)",
            await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1]))
        halfPressReleased = true
        log("shutter via ReleaseOn/Off half+full pair")
    }

    // MARK: - Properties

    /// Canon property set: data phase is { u32 totalSize, u32 propCode, u32 value }.
    public func setProperty(_ propCode: UInt32, _ value: UInt32, name: String) async throws {
        var data = Data()
        data.appendLE(UInt32(12))
        data.appendLE(propCode)
        data.appendLE(value)
        try await expectOK("SetProp \(name)",
            await transport.send(code: CanonOp.setDevicePropValueEx, outData: data))
        log("set \(name)")
    }

    // MARK: - Teardown / recovery

    public func disconnect() {
        eventLoopTask?.cancel()
        liveViewTask?.cancel()
        state = .idle
    }

    private func expectOK(_ operation: String, _ result: PTPTransactionResult) throws {
        // No parsed response container at all: some passthrough stacks swallow
        // it on success. Log loudly, treat as OK — Phase 0 finding to record.
        guard let response = result.response else {
            log("\(operation): no response container (raw \(result.rawInbound.count) bytes) — assuming OK")
            return
        }
        guard response.code == PTPResponseCode.ok else {
            log(String(format: "%@ failed: 0x%04X", operation, response.code))
            throw EOSError.badResponse(operation: operation, code: response.code)
        }
    }
}

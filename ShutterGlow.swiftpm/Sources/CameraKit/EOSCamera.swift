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
            // Capture to the CARD, not the host.
            //
            // Host destination (4) is why the shutter would not fire. Hardware
            // 2026-08-03: with Host set, every release path returned DeviceBusy
            // — bare release, full-press alone, half+full, and with EVF torn
            // down. With Card set, the same commands were accepted. Cascable
            // Studio confirmed the split from the other side: it captures on
            // this exact body and cable, and treats "PC Only / Host Only" as a
            // separate paid mode, because host destination needs a real
            // object-transfer handshake (RequestObjectTransfer -> GetPartialObject
            // -> TransferComplete) that this app has never implemented. Asking
            // the body to hand an image to a host that will not collect it is
            // what it was refusing to do.
            //
            // This setting also PERSISTS on the camera after disconnect. Left
            // on Host, the body writes photos nowhere at all — including for
            // the physical shutter, at a real event, silently. resetDeviceState()
            // below puts it back; see disconnect().
            try await setProperty(CanonProp.captureDestination,
                                  CanonProp.captureDestinationCard,
                                  name: "CaptureDestination=Card")
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
                                // Cached because Canon EOS has no synchronous
                                // property read — this event is the only place
                                // the value ever appears, and triggerShutter
                                // needs it to say whether a refused release is
                                // explained by One-Shot AF on a lens that
                                // cannot focus.
                                if propcode == CanonProp.focusMode, record.payload.count >= 8 {
                                    await self.recordFocusMode(record.payload.readLE(UInt32.self, at: 4))
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

    /// Last focus mode the body reported (3 = manual). Only ever populated by
    /// the PropValueChanged event above; there is no synchronous read.
    private var lastFocusMode: UInt32?

    private func recordFocusMode(_ mode: UInt32) { lastFocusMode = mode }

    /// Object handle of the most recent capture, taken from Canon's own
    /// ObjectAdded/RequestObjectTransfer event.
    private var lastCapturedHandle: UInt32?

    /// Trigger the shutter and return the resulting full-resolution image.
    public func capturePhoto() async throws -> Data {
        eventLoopTask?.cancel()
        isCapturePaused = true
        defer {
            isCapturePaused = false
            // Only re-arm the GetEvent poll loop if we're still connected.
            // If disconnect() ran while a capture was in flight (booth
            // teardown, brand switch, reconnect), the capture's throw would
            // otherwise resurrect a polling loop against a dead transport,
            // error-looping every ~1.5s until this instance deallocates.
            if state == .connected || state == .liveView {
                startEventLoop()
            }
        }
        lastCapturedHandle = nil
        try await triggerShutter()

        // Prefer Canon's own object handle over waiting for ImageCaptureCore
        // to notice a new file. ICC's catalog is populated at session open and
        // does not reliably re-announce a shot taken mid-session — hardware
        // 2026-08-03: the shutter fired, ObjectAddedEx64 arrived within three
        // seconds carrying the handle, and ICC's file-added callback never
        // came at all inside a 15s wait. PTPIPTransport has downloaded
        // captures this way over Wi-Fi from the start; the only reason USB
        // could not was that the transport discarded every data phase, so
        // GetObject returned nothing to return.
        if let handle = lastCapturedHandle {
            do {
                return try await downloadObject(handle)
            } catch {
                log("GetObject on handle 0x\(String(handle, radix: 16)) failed (\(error)); falling back to the file catalog")
            }
        }
        return try await transport.nextCapturedFile(timeout: 15)
    }

    /// Pull a captured image off the camera by its object handle.
    private func downloadObject(_ handle: UInt32) async throws -> Data {
        let info = try await transport.send(code: StandardPTPOp.getObjectInfo, parameters: [handle])
        if info.payload.count >= 12 {
            // Size lives at offset 8 of the ObjectInfo dataset: StorageID(4) +
            // ObjectFormat(2) + ProtectionStatus(2) + ObjectCompressedSize(4).
            log("object info: \(info.payload.readLE(UInt32.self, at: 8)) bytes reported")
        }

        let object = try await transport.send(code: StandardPTPOp.getObject, parameters: [handle])
        if let code = object.response?.code, code != PTPResponseCode.ok {
            throw EOSError.badResponse(operation: "GetObject", code: code)
        }
        guard !object.payload.isEmpty else {
            throw EOSError.badResponse(operation: "GetObject (empty payload)", code: nil)
        }
        log("downloaded \(object.payload.count) bytes for handle 0x\(String(handle, radix: 16))")
        return object.payload
    }

    /// Fire the shutter, and prove it fired.
    ///
    /// Three release paths exist in the record and they contradict each other,
    /// so this tries each in turn and reports which one the body actually
    /// honours. One hardware run settles a question that has otherwise cost a
    /// build-sideload-test cycle per theory.
    ///
    /// The contradiction: PHASE0.md's hardware table records T4 passing at
    /// 2.79s using bare RemoteRelease 0x910F, while the comment that used to
    /// live here called 0x910F "a no-op, not implemented on EOS". Both cannot
    /// be true. Rather than pick one, ask the camera.
    ///
    /// **A response of 0x2001 OK does not mean the shutter fired.** That was
    /// established on hardware: with CaptureDestination=Card the half+full
    /// pair returned OK for every command and no image ever appeared. So each
    /// method below is judged on whether an object event arrives afterwards,
    /// not on its response code.
    private func triggerShutter() async throws {
        // Clear any half-press left holding from an earlier failed attempt.
        // A stuck half-press does genuinely make the body refuse every
        // subsequent full-press with DeviceBusy.
        _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1])

        switch lastFocusMode {
        case .some(3):
            log("focus mode at capture: 3 (manual) — AF is not a factor")
        case .some(let mode):
            log("focus mode at capture: \(mode) (autofocus). A lens that cannot AF will refuse to release in One-Shot, whatever the release path.")
        case nil:
            log("focus mode at capture: not reported yet")
        }

        // Take the body's UI before attempting any release, and give it back
        // afterwards whatever happens.
        //
        // This is the one thing Canon's own EDSDK and libgphoto2 both do that
        // this code never did. It fits the 2026-08-03 evidence precisely: the
        // body accepted property sets, half-presses and event polls, and
        // refused only the full press, with DeviceBusy, across four unrelated
        // release sequences, in both AF and MF, with EVF up and torn down.
        // "Busy" was never about focus or live view — it was the body saying
        // it is being operated by a human.
        //
        // Failure is logged rather than thrown: if a body does not implement
        // the opcode the ladder below should still get its chance.
        let lock = try? await transport.send(code: CanonOp.setUILock)
        log("SetUILock: \(code(of: lock))")

        // Released on BOTH paths, awaited. Swift cannot await inside defer, and
        // a UI lock handed back from a detached Task can still be held when the
        // next capture starts or when disconnect runs — leaving the body under
        // host control with nothing driving it, which is the same family of
        // stuck state as the PC-mode icon.
        var attempts: [String] = []

        for method in ShutterMethod.allCases {
            let outcome = await tryRelease(method)
            attempts.append("\(method.label): \(outcome.summary)")
            if outcome.fired {
                log("SHUTTER FIRED via \(method.label)")
                log("  ladder: \(attempts.joined(separator: " | "))")
                _ = try? await transport.send(code: CanonOp.resetUILock)
                return
            }
        }

        log("no release method produced an object event")
        log("  ladder: \(attempts.joined(separator: " | "))")
        _ = try? await transport.send(code: CanonOp.resetUILock)
        throw EOSError.badResponse(operation: "triggerShutter (all methods)", code: nil)
    }

    /// The release sequences worth trying, cheapest and least invasive first.
    private enum ShutterMethod: CaseIterable {
        /// Legacy single-opcode release. PHASE0.md records this working.
        case bareRelease
        /// Full press with no half press. Correct when the body is in manual
        /// focus: the half press exists only to run AF, and on a lens that
        /// cannot AF it is the thing that hangs.
        case fullPressOnly
        /// Half press then full press — libgphoto2's reference sequence.
        case halfThenFull
        /// Live view fully torn down (EVFOutputDevice=0) for the duration of
        /// the release, then restored.
        ///
        /// A comment in this file said this was tried and made no difference.
        /// That test ran while the transport was discarding every data phase,
        /// so nothing worked and it proved nothing — as does every other
        /// "tried X, no difference" note written before 2026-08-01. Retrying
        /// it because the one consistent correlation across all hardware runs
        /// is CaptureDestination: Card releases fine, Host always returns
        /// DeviceBusy. With EVFOutputDevice=cameraAndHost the body is being
        /// asked to stream live view to the host and buffer a full-res image
        /// for the host at the same time, which it may simply refuse.
        case evfOffThenFull

        var label: String {
            switch self {
            case .bareRelease: "bare RemoteRelease 0x910F"
            case .fullPressOnly: "full press only (no AF half-press)"
            case .halfThenFull: "half+full pair"
            case .evfOffThenFull: "EVF off, then full press"
            }
        }
    }

    private struct ReleaseOutcome {
        let fired: Bool
        let summary: String
    }

    private func tryRelease(_ method: ShutterMethod) async -> ReleaseOutcome {
        var note = ""
        switch method {
        case .bareRelease:
            let r = try? await transport.send(code: CanonOp.remoteRelease)
            note = code(of: r)

        case .fullPressOnly:
            // Both AF flags, since neither has been ruled out for this path.
            for afParam: UInt32 in [1, 0] {
                let r = try? await transport.send(code: CanonOp.remoteReleaseOn, parameters: [2, afParam])
                note += "af\(afParam)=\(code(of: r)) "
                _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [2])
                if await objectEventArrived() {
                    return ReleaseOutcome(fired: true, summary: note + "-> object event")
                }
            }

        case .halfThenFull:
            let half = try? await transport.send(code: CanonOp.remoteReleaseOn, parameters: [1, 0])
            note = "half=\(code(of: half)) "
            // Give AF a moment where a lens can actually focus.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let full = try? await transport.send(code: CanonOp.remoteReleaseOn, parameters: [2, 1])
            note += "full=\(code(of: full)) "
            _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [2])
            _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1])

        case .evfOffThenFull:
            // EVF is restored on every exit path below, awaited rather than
            // deferred into a detached Task. Leaving the body with EVF off
            // kills live view for the rest of the session — the one thing
            // currently working — and a detached restore lands at an
            // unpredictable point, possibly after live view has already tried
            // to resume against a dark sensor.
            try? await setProperty(CanonProp.evfOutputDevice, 0, name: "EVFOutputDevice=off (release attempt)")
            try? await Task.sleep(nanoseconds: 400_000_000)
            for afParam: UInt32 in [1, 0] {
                let r = try? await transport.send(code: CanonOp.remoteReleaseOn, parameters: [2, afParam])
                note += "af\(afParam)=\(code(of: r)) "
                _ = try? await transport.send(code: CanonOp.remoteReleaseOff, parameters: [2])
                if await objectEventArrived() {
                    try? await setProperty(CanonProp.evfOutputDevice, 3,
                                           name: "EVFOutputDevice=cameraAndHost (restored)")
                    return ReleaseOutcome(fired: true, summary: note + "-> object event")
                }
            }
            try? await setProperty(CanonProp.evfOutputDevice, 3,
                                   name: "EVFOutputDevice=cameraAndHost (restored)")
        }

        let fired = await objectEventArrived()
        return ReleaseOutcome(fired: fired, summary: note + (fired ? "-> object event" : "-> nothing"))
    }

    private func code(of result: PTPTransactionResult?) -> String {
        guard let c = result?.response?.code else { return "no-response" }
        return String(format: "0x%04X", c)
    }

    /// Poll GetEvent briefly for any signal that an image now exists.
    ///
    /// Which event arrives depends on where the image went:
    /// ObjectAddedEx/64 for a card capture, RequestObjectTransfer (0xC186)
    /// for CaptureDestination=Host, where nothing is ever written to the card
    /// and the card-object events therefore never come. Any of the three
    /// proves the shutter released, which a response code does not.
    private func objectEventArrived(timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await transport.send(code: CanonOp.getEvent) {
                for record in CanonEventRecord.parse(result.payload) {
                    switch record.type {
                    case CanonEvent.objectAddedEx, CanonEvent.objectAddedEx64,
                         CanonEvent.requestObjectTransfer:
                        // Keep the handle. This poll is the only place it ever
                        // appears — consuming the record and reporting a bare
                        // "yes it fired" would leave the image identified by
                        // nothing, and the download below with no way to ask
                        // for it.
                        if record.payload.count >= 4 {
                            lastCapturedHandle = record.payload.readLE(UInt32.self, at: 0)
                        }
                        log(String(format: "  object event 0x%04X (%d bytes) handle 0x%08X",
                                   record.type, record.payload.count, lastCapturedHandle ?? 0))
                        return true
                    case CanonEvent.olcInfoChanged:
                        log("  OLCInfoChanged (focus confirm) seen")
                    default:
                        break
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
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

    public func disconnect() async {
        // Hand the camera back before dropping the session. Canon properties
        // set over PTP PERSIST after the USB connection ends — an operator who
        // unplugs mid-session and then shoots the rest of the night on the
        // physical shutter would otherwise be running a body we quietly
        // reconfigured, with live view redirected and (before 2026-08-03)
        // capture destined for a host that is no longer there.
        //
        // Stop the polling loops FIRST. Restoring properties underneath a live
        // view poll running at 30fps means competing for the same session
        // while it is being handed back.
        eventLoopTask?.cancel()
        liveViewTask?.cancel()

        // Awaited, not fired into the dark. These used to run in a detached
        // Task while the transport was already closing, so they raced the
        // session teardown and frequently never landed — which is how a body
        // could still end up left on Host, the exact failure this restore
        // exists to prevent.
        //
        // Bounded so a pulled cable cannot hang teardown: on the yanked-cable
        // path every send fails fast anyway, and the whole block is best
        // effort by design.
        // Properties first, remote mode last — the body stops accepting
        // property sets once it is out of remote mode, so the order is not
        // interchangeable.
        await bounded(seconds: 1.5) { [transport] in
            _ = try? await transport.send(code: CanonOp.resetUILock)
            var card = Data()
            card.appendLE(UInt32(12))
            card.appendLE(CanonProp.captureDestination)
            card.appendLE(CanonProp.captureDestinationCard)
            _ = try? await transport.send(code: CanonOp.setDevicePropValueEx, outData: card)
            var evf = Data()
            evf.appendLE(UInt32(12))
            evf.appendLE(CanonProp.evfOutputDevice)
            evf.appendLE(UInt32(0))
            _ = try? await transport.send(code: CanonOp.setDevicePropValueEx, outData: evf)
        }

        // Its own budget, deliberately. Sharing one with the restores above
        // meant a slow property set could eat the whole allowance and this
        // never ran — leaving the body in remote mode, showing the PC icon,
        // and refusing to reconnect until power-cycled. Of everything in this
        // teardown, this is the one that must not be skipped.
        await bounded(seconds: 1.5) { [transport] in
            _ = try? await transport.send(code: CanonOp.setRemoteMode, parameters: [0])
        }
        log("remote mode released")

        state = .idle
    }

    /// Run `work`, giving up after `seconds`. Teardown also happens on the
    /// yanked-cable path where every send hangs until it fails, and a booth
    /// must not stall there.
    private func bounded(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
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

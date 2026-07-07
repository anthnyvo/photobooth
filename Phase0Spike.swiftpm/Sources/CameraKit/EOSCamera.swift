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

    /// Diagnostic log lines, mirrored to the spike UI.
    private var logSink: (@Sendable (String) -> Void)?

    public init(transport: any PTPTransport) {
        self.transport = transport
    }

    public func setLogSink(_ sink: @escaping @Sendable (String) -> Void) {
        logSink = sink
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
            // Route captures to the host, not the card — see CanonProp doc
            // comment. Non-fatal if the body rejects it (older bodies may
            // not expose this property); log and continue either way.
            do {
                try await setProperty(CanonProp.captureDestination,
                                      CanonProp.captureDestinationHost,
                                      name: "CaptureDestination=Host")
            } catch {
                log("CaptureDestination=Host rejected (\(error)) — continuing, capture may still hit the card")
            }
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
                    for record in records where record.type != CanonEvent.propValueChanged {
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
        // 3 = cameraAndHost, so the camera's own screen stays live too.
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

        liveViewTask?.cancel()
        liveViewTask = Task { [weak self] in
            var windowStart = ContinuousClock.now
            var windowFrames = 0
            var lastDiagLog = ContinuousClock.now.advanced(by: .seconds(-10))
            while !Task.isCancelled {
                guard let self else { break }
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
            continuation.finish()
        }
        return stream
    }

    public func stopLiveView() async throws {
        liveViewTask?.cancel()
        liveViewTask = nil
        try await setProperty(CanonProp.evfOutputDevice, 0, name: "EVFOutputDevice=off")
        state = .connected
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
    /// skips its own polling entirely rather than racing the shutter/download
    /// calls for turns on the shared connection. Found on hardware: live
    /// view's continuous ~10ms-cadence loop was starving the shutter command
    /// out of ever running at all (0x910F never even appeared on the wire
    /// during a 15s capture timeout) — cancelling the *event* poller alone
    /// wasn't enough, since live view is the far busier of the two.
    private(set) var isCapturePaused = false

    /// Trigger the shutter and return the resulting full-resolution image.
    public func capturePhoto() async throws -> Data {
        // Pause both background pollers for the capture window: over
        // PTP/IP, nextCapturedFile listens on the dedicated event channel
        // and triggerShutter/download need clear turns on the command
        // connection. Harmless for USB, whose nextCapturedFile doesn't
        // touch either at all (ImageCaptureCore announces files on its own).
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
        // it's a legacy PowerShot-era release, not implemented on EOS. That's
        // why capture logged "shutter via RemoteRelease" yet GetEvent never
        // produced a single record afterward: nothing was actually triggered.
        // EOS bodies need the half-press (AF) + full-press pair instead,
        // matching libgphoto2's ptp2 camlib and EOS Utility's own sequence.
        try await expectOK("ReleaseOn(half)",
            await transport.send(code: CanonOp.remoteReleaseOn, parameters: [1, 0]))
        try? await Task.sleep(nanoseconds: 300_000_000)
        // The body answers full-press with DeviceBusy (0x2019) while it's
        // still settling from the half-press/AF — confirmed on hardware,
        // not a permanent rejection. Retry with backoff instead of failing;
        // this is the standard EOS remote-capture pattern (libgphoto2 does
        // the same).
        var fullPressAttempt = 0
        while true {
            fullPressAttempt += 1
            let result = try await transport.send(code: CanonOp.remoteReleaseOn, parameters: [2, 0])
            if result.response == nil || result.response?.code == PTPResponseCode.ok {
                break
            }
            if result.response?.code == PTPResponseCode.deviceBusy, fullPressAttempt < 10 {
                log("ReleaseOn(full) busy (attempt \(fullPressAttempt)), retrying")
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            log(String(format: "ReleaseOn(full) failed: 0x%04X", result.response?.code ?? 0))
            throw EOSError.badResponse(operation: "ReleaseOn(full)", code: result.response?.code)
        }
        try await expectOK("ReleaseOff(full)",
            await transport.send(code: CanonOp.remoteReleaseOff, parameters: [2]))
        try await expectOK("ReleaseOff(half)",
            await transport.send(code: CanonOp.remoteReleaseOff, parameters: [1]))
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

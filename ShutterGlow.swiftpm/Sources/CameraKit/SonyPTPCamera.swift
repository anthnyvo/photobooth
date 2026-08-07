import Foundation

public enum SonyPTPError: Error {
    case badResponse(operation: String, code: UInt16?)
    case noLiveViewRoute
}

/// Sony Alpha over PTP — the "PC Remote" USB mode, not the UVC webcam mode.
///
/// This is the path that gives a real shutter, full sensor resolution and
/// flash sync, where `UVCWebcamCamera` grabs a frame out of a video stream.
/// Cascable demonstrates it works on iOS for the α7 family, so the ceiling is
/// implementation effort rather than the platform.
///
/// **Camera-side setting: USB Connection Mode must be `PC Remote`**, called
/// "Remote Shooting" in the a7 IV menu. `USB Streaming` is the webcam mode and
/// is mutually exclusive with this — the body speaks one or the other, never
/// both.
///
/// ## Status
///
/// The handshake and capture path are built from libgphoto2's headers and
/// initialisation order. **Live view is not** — no primary source for how
/// Sony hands over a preview frame was found, so `startLiveView` probes
/// several candidate routes on hardware and reports which one works rather
/// than committing to a guess. Nothing here has run against a camera yet.
public actor SonyPTPCamera: TetheredCamera {

    private let transport: any PTPTransport
    private var logSink: (@Sendable (String) -> Void)?
    private var liveViewTask: Task<Void, Never>?
    private var liveViewContinuation: AsyncStream<Data>.Continuation?
    /// Which live view route the body accepted, once discovered. Nil until a
    /// probe has succeeded; -1 meaning "none worked" is expressed as the enum
    /// being absent plus liveViewUnavailable.
    private var liveViewRoute: LiveViewRoute?
    private var liveViewUnavailable = false

    public init(transport: any PTPTransport) {
        self.transport = transport
    }

    public func setLogSink(_ sink: @escaping @Sendable (String) -> Void) {
        logSink = sink
    }

    private func log(_ message: String) {
        logSink?("[Sony] \(message)")
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        // Sony reports battery inside GetAllExtDevicePropInfo's blob. Parsing
        // that dataset is a separate piece of work and the booth treats
        // battery as optional, so it is deliberately not guessed at here.
    }

    // MARK: - Connect

    /// Sony's three-step SDIO handshake.
    ///
    /// The body accepts almost nothing before this completes, which is why a
    /// plain PTP client appears to do nothing at all against a Sony. Order is
    /// taken from libgphoto2's `fixup_cached_deviceinfo`: connect(1),
    /// connect(2), read the vendor property lists, then connect(3). The
    /// device-info read between steps 2 and 3 is not optional — the body
    /// expects it, and skipping it is a known way to have step 3 refused.
    public func enterRemoteMode() async throws {
        try await expectOK("SDIO_Connect(1)",
            await transport.send(code: SonyOp.sdioConnect, parameters: [1, 0, 0]))
        try await expectOK("SDIO_Connect(2)",
            await transport.send(code: SonyOp.sdioConnect, parameters: [2, 0, 0]))

        // 0xC8 is the version libgphoto2 asks for. The payload is the vendor
        // opcode/property lists; nothing here needs to parse it yet, but the
        // call itself is part of the handshake.
        let info = try await transport.send(code: SonyOp.sdioGetExtDeviceInfo, parameters: [0x00C8])
        log("ext device info: \(info.payload.count) bytes")

        try await expectOK("SDIO_Connect(3)",
            await transport.send(code: SonyOp.sdioConnect, parameters: [3, 0, 0]))
        log("SDIO handshake complete")
    }

    // MARK: - Capture

    /// Half-press then full-press, mirroring how the physical button behaves.
    ///
    /// Sony models the shutter as two properties holding a button state rather
    /// than as a capture opcode: 2 is "pressed", 1 is "released". Both must be
    /// released afterwards or the body is left holding a virtual button down,
    /// which is the Sony equivalent of the stuck half-press that made Canon
    /// refuse every subsequent shot.
    public func capturePhoto() async throws -> Data {
        try await setControl(SonyProp.autofocus, 2)
        // Give AF a beat to confirm. On a manual lens this simply passes.
        try? await Task.sleep(nanoseconds: 300_000_000)
        try await setControl(SonyProp.capture, 2)
        log("shutter pressed")

        // Release is AWAITED on both paths rather than deferred into a
        // detached Task. Swift cannot await inside defer, and firing the
        // release off unordered is the Sony version of Canon's stuck
        // half-press: the body is left holding a virtual button down, and the
        // next capture finds it busy. Explicit do/catch is the price of
        // getting that right.
        do {
            let data = try await transport.nextCapturedFileViaObjectAdded(timeout: 20)
            await releaseShutterButtons()
            return data
        } catch {
            await releaseShutterButtons()
            throw error
        }
    }

    private func releaseShutterButtons() async {
        _ = try? await Self.sendControl(transport, SonyProp.capture, 1)
        _ = try? await Self.sendControl(transport, SonyProp.autofocus, 1)
    }

    private func setControl(_ property: UInt32, _ value: UInt16) async throws {
        let result = try await Self.sendControl(transport, property, value)
        if let code = result.response?.code, code != PTPResponseCode.ok {
            throw SonyPTPError.badResponse(
                operation: String(format: "SDIO_ControlDevice 0x%04X = %u", property, value),
                code: code)
        }
    }

    /// Static so the release path in `capturePhoto`'s defer can run without
    /// re-entering the actor while it is unwinding.
    private static func sendControl(_ transport: any PTPTransport,
                                    _ property: UInt32,
                                    _ value: UInt16) async throws -> PTPTransactionResult {
        // Sony carries the value in the data phase, not as a parameter.
        var data = Data()
        data.appendLE(value)
        return try await transport.send(code: SonyOp.sdioControlDevice,
                                        parameters: [property],
                                        outData: data)
    }

    // MARK: - Live view

    /// The routes worth trying for a preview frame, most likely first.
    ///
    /// Deliberately a list rather than a decision. Unlike everything else in
    /// this file, none of these is backed by a primary source — so the body
    /// gets asked instead of assumed, and whichever answers is logged and
    /// reused. Guessing one and building on it is exactly what cost three
    /// weeks on the Canon path.
    private enum LiveViewRoute: CaseIterable {
        /// Standard GetObject against Sony's reserved live view handle.
        case getObject
        /// Sony's own chunked read against the same handle. Some bodies only
        /// serve large/streaming objects this way.
        case partialLargeObject

        var label: String {
            switch self {
            case .getObject: "GetObject(0xFFFFC002)"
            case .partialLargeObject: "SDIO_GetPartialLargeObject(0xFFFFC002)"
            }
        }
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        liveViewContinuation = continuation
        startPolling()
        return stream
    }

    private func startPolling() {
        liveViewTask?.cancel()
        liveViewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                guard let frame = await self.fetchFrame() else {
                    // No route works on this body. Stop rather than hammer it;
                    // the booth runs feed-less, same as GenericPTPCamera.
                    if await self.liveViewUnavailable { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                await self.yieldFrame(frame)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func yieldFrame(_ frame: Data) {
        liveViewContinuation?.yield(frame)
    }

    private func fetchFrame() async -> Data? {
        // Once a route is known, stop probing.
        if let route = liveViewRoute {
            return await attempt(route)
        }
        guard !liveViewUnavailable else { return nil }

        for route in LiveViewRoute.allCases {
            if let frame = await attempt(route) {
                liveViewRoute = route
                log("live view route: \(route.label) — \(frame.count) bytes")
                return frame
            }
            log("live view route \(route.label): nothing usable")
        }

        liveViewUnavailable = true
        log("no live view route worked. Capture still functions; the booth runs without a preview.")
        return nil
    }

    private func attempt(_ route: LiveViewRoute) async -> Data? {
        let result: PTPTransactionResult?
        switch route {
        case .getObject:
            result = try? await transport.send(code: StandardPTPOp.getObject,
                                               parameters: [SonyObject.liveViewFrame])
        case .partialLargeObject:
            // offset lo, offset hi, max bytes — a frame is comfortably under
            // 1MB, and asking for more than exists is not an error here.
            result = try? await transport.send(code: SonyOp.sdioGetPartialLargeObject,
                                               parameters: [SonyObject.liveViewFrame, 0, 0, 1_000_000])
        }

        guard let payload = result?.payload, !payload.isEmpty else { return nil }
        // Sony wraps the JPEG in a header whose length varies by model, so
        // scan rather than assume an offset. LiveViewParser already handles
        // both the structured and scan cases.
        if case .frame(let jpeg, _) = LiveViewParser.extractJPEG(payload) {
            return jpeg
        }
        return nil
    }

    public func disconnect() {
        liveViewTask?.cancel()
        liveViewTask = nil
        liveViewContinuation?.finish()
        liveViewContinuation = nil
    }

    private func expectOK(_ operation: String, _ result: PTPTransactionResult) throws {
        guard let code = result.response?.code else { return }
        if code != PTPResponseCode.ok {
            throw SonyPTPError.badResponse(operation: operation, code: code)
        }
    }
}

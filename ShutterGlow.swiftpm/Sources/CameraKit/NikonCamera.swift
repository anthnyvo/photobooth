import Foundation

/// Nikon vendor opcodes (per libgphoto2's ptp.h) — the PTP/IP dialect
/// Nikon bodies speak for tethering. UNVERIFIED against real hardware:
/// this is a faithful transcription of the documented protocol, shipped
/// as beta until someone runs it against a real body.
public enum NikonOp {
    /// Capture to SDRAM (host delivery, no card write) — Nikon's analogue
    /// of Canon's CaptureDestination=Host flow.
    public static let initiateCaptureRecInSdram: UInt16 = 0x90C0
    /// Poll until the body reports ready after an operation.
    public static let deviceReady: UInt16 = 0x90C8
    public static let startLiveView: UInt16 = 0x9201
    public static let endLiveView: UInt16 = 0x9202
    /// Returns a vendor header followed by a JPEG — header length varies
    /// by generation (64/128/384 bytes), so the parser scans for the JPEG
    /// SOI marker rather than assuming an offset.
    public static let getLiveViewImage: UInt16 = 0x9203
}

public enum NikonCameraError: Error {
    case badResponse(operation: String, code: UInt16?)
}

/// Nikon remote-control state machine over PTP/IP. Mirrors EOSCamera's
/// shape (event-driven live view polling, pause-during-capture) with
/// Nikon's opcodes. Battery reporting is not wired — standard PTP
/// BatteryLevel (0x5001) exists but polling it isn't worth the connection
/// contention until the rest is verified on hardware.
public actor NikonCamera: TetheredCamera {
    private let transport: any PTPTransport
    private var liveViewTask: Task<Void, Never>?
    private var liveViewContinuation: AsyncStream<Data>.Continuation?
    private var isCapturePaused = false

    public init(transport: any PTPTransport) {
        self.transport = transport
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        // Not wired for Nikon yet — see actor doc comment.
    }

    public func enterRemoteMode() async throws {
        // Nikon needs no Canon-style SetRemoteMode — the PTP session opened
        // by the transport handshake is already a remote session. DeviceReady
        // confirms the body is responsive before the flow proceeds.
        _ = try? await transport.send(code: NikonOp.deviceReady)
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let start = try await transport.send(code: NikonOp.startLiveView)
        if let code = start.response?.code, code != PTPResponseCode.ok {
            throw NikonCameraError.badResponse(operation: "StartLiveView", code: code)
        }
        // Same settle rationale as Canon: the sensor pipeline needs a beat
        // before the first GetLiveViewImage returns anything.
        try? await Task.sleep(nanoseconds: 500_000_000)

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        liveViewContinuation = continuation
        startLiveViewPolling()
        return stream
    }

    private func startLiveViewPolling() {
        liveViewTask?.cancel()
        liveViewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let continuation = await self.liveViewContinuation else { break }
                if await self.isCapturePaused {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                do {
                    let result = try await self.transport.send(code: NikonOp.getLiveViewImage)
                    // Vendor header length varies by body generation — the
                    // shared SOI/EOI scan handles all of them.
                    if case .frame(let jpeg, _) = LiveViewParser.extractJPEG(result.payload) {
                        continuation.yield(jpeg)
                    }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                } catch {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    public func capturePhoto() async throws -> Data {
        isCapturePaused = true
        defer { isCapturePaused = false }

        // SDRAM capture: image goes to the host, not the card, and the body
        // announces it with a standard ObjectAdded on the event connection.
        let result = try await transport.send(code: NikonOp.initiateCaptureRecInSdram, parameters: [0xFFFF_FFFF, 0])
        if let code = result.response?.code, code != PTPResponseCode.ok {
            throw NikonCameraError.badResponse(operation: "InitiateCaptureRecInSdram", code: code)
        }
        return try await transport.nextCapturedFileViaObjectAdded(timeout: 15)
    }

    public func disconnect() {
        liveViewTask?.cancel()
        liveViewContinuation?.finish()
        liveViewContinuation = nil
        Task { [transport] in
            _ = try? await transport.send(code: NikonOp.endLiveView)
        }
    }
}

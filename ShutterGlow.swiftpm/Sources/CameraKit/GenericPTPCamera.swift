import Foundation

public enum GenericPTPError: Error {
    case badResponse(operation: String, code: UInt16?)
}

/// Lowest-common-denominator PTP/IP camera: standard InitiateCapture plus
/// ObjectAdded-driven download, nothing vendor-specific. Live view is NOT
/// part of standard PTP, so the stream finishes immediately and the booth
/// runs feed-less — capture, strips, print, and share all still work;
/// live-view-dependent extras (AR props, Boomerang/GIF, timelapse, smile
/// shutter) simply have nothing to record. Beta: untested on hardware.
public actor GenericPTPCamera: TetheredCamera {
    /// Standard PTP InitiateCapture — the one capture opcode every
    /// compliant body must implement.
    private static let initiateCapture: UInt16 = 0x100E

    private let transport: any PTPTransport

    public init(transport: any PTPTransport) {
        self.transport = transport
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {}

    public func enterRemoteMode() async throws {
        // Standard PTP has no remote-mode handshake beyond the session the
        // transport already opened.
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.finish()
        return stream
    }

    public func capturePhoto() async throws -> Data {
        let result = try await transport.send(code: Self.initiateCapture, parameters: [0, 0])
        if let code = result.response?.code, code != PTPResponseCode.ok {
            throw GenericPTPError.badResponse(operation: "InitiateCapture", code: code)
        }
        return try await transport.nextCapturedFileViaObjectAdded(timeout: 20)
    }

    public func disconnect() {}
}

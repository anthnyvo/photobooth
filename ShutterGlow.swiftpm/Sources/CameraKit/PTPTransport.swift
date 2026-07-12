import Foundation

/// Common interface EOSCamera talks to — lets the same Canon protocol logic
/// run over either USB (ICCTransport, a class) or Wi-Fi (PTPIPTransport, an
/// actor). Deliberately not constrained to `Actor`/`AnyObject` so either
/// concurrency shape can conform.
public protocol PTPTransport: Sendable {
    func send(code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPTransactionResult
    func nextCapturedFile(timeout: TimeInterval) async throws -> Data
    /// Vendor-neutral capture retrieval (Nikon/generic): waits for a
    /// standard PTP ObjectAdded event. Declared as a real protocol
    /// requirement — a protocol-extension-only method here is resolved by
    /// STATIC dispatch against the `any PTPTransport` existential type that
    /// NikonCamera/GenericPTPCamera actually hold, which silently calls the
    /// extension's default (nextCapturedFile) even when the concrete type
    /// (PTPIPTransport) has its own override. That bug meant Nikon/generic
    /// capture retrieval always ran Canon's GetEvent polling instead, and
    /// always timed out. See PTPIPTransport's override for the real
    /// ObjectAdded wait; the extension below is only for ICCTransport
    /// (USB/Canon-only — no dedicated event channel to wait on).
    func nextCapturedFileViaObjectAdded(timeout: TimeInterval) async throws -> Data
    var events: AsyncStream<TransportEvent> { get }
}

// Default-carrying convenience overload — protocol requirements can't declare
// default parameter values, so EOSCamera's existing call sites (many of which
// omit parameters/outData) need this to keep working against `any PTPTransport`.
public extension PTPTransport {
    func send(code: UInt16, parameters: [UInt32] = [], outData: Data? = nil) async throws -> PTPTransactionResult {
        try await send(code: code, parameters: parameters, outData: outData)
    }

    /// Default for transports with no dedicated event channel to wait on
    /// (ICCTransport/USB — Canon-only, no Nikon/generic use case there):
    /// falls back to the Canon-tuned nextCapturedFile, which also checks
    /// standard ObjectAdded codes. PTPIPTransport overrides this with a
    /// real ObjectAdded wait and must keep doing so now that this is a
    /// protocol requirement (an override, not an extension default, so
    /// dispatch is correct through the existential).
    func nextCapturedFileViaObjectAdded(timeout: TimeInterval) async throws -> Data {
        try await nextCapturedFile(timeout: timeout)
    }
}

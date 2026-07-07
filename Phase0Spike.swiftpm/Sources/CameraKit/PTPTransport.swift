import Foundation

/// Common interface EOSCamera talks to — lets the same Canon protocol logic
/// run over either USB (ICCTransport, a class) or Wi-Fi (PTPIPTransport, an
/// actor). Deliberately not constrained to `Actor`/`AnyObject` so either
/// concurrency shape can conform.
public protocol PTPTransport: Sendable {
    func send(code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPTransactionResult
    func nextCapturedFile(timeout: TimeInterval) async throws -> Data
    var events: AsyncStream<TransportEvent> { get }
}

// Default-carrying convenience overload — protocol requirements can't declare
// default parameter values, so EOSCamera's existing call sites (many of which
// omit parameters/outData) need this to keep working against `any PTPTransport`.
public extension PTPTransport {
    func send(code: UInt16, parameters: [UInt32] = [], outData: Data? = nil) async throws -> PTPTransactionResult {
        try await send(code: code, parameters: parameters, outData: outData)
    }
}

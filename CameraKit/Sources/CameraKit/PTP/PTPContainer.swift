import Foundation

/// A PTP container: the 12-byte header (length, type, code, transactionID)
/// followed by either parameters (command/response) or a payload (data phase).
/// All fields are little-endian on the wire.
public struct PTPContainer: Sendable {
    public enum Kind: UInt16, Sendable {
        case command = 1
        case data = 2
        case response = 3
        case event = 4
    }

    public var kind: Kind
    public var code: UInt16
    public var transactionID: UInt32
    /// Up to 5 UInt32 parameters for command/response/event containers.
    public var parameters: [UInt32]
    /// Payload for data-phase containers; empty otherwise.
    public var payload: Data

    public init(kind: Kind, code: UInt16, transactionID: UInt32,
                parameters: [UInt32] = [], payload: Data = Data()) {
        self.kind = kind
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
        self.payload = payload
    }

    /// Serialize to wire format.
    public func encoded() -> Data {
        var data = Data(capacity: 12 + parameters.count * 4 + payload.count)
        let body: Data
        switch kind {
        case .command, .response, .event:
            var params = Data()
            for p in parameters { params.appendLE(p) }
            body = params
        case .data:
            body = payload
        }
        data.appendLE(UInt32(12 + body.count))
        data.appendLE(kind.rawValue)
        data.appendLE(code)
        data.appendLE(transactionID)
        data.append(body)
        return data
    }

    /// Parse one container starting at `offset`. Returns nil if the bytes
    /// don't form a plausible container.
    public static func parse(_ data: Data, at offset: Int = 0) -> (container: PTPContainer, length: Int)? {
        guard data.count - offset >= 12 else { return nil }
        let length = Int(data.readLE(UInt32.self, at: offset))
        guard length >= 12, offset + length <= data.count else { return nil }
        guard let kind = Kind(rawValue: data.readLE(UInt16.self, at: offset + 4)) else { return nil }
        let code = data.readLE(UInt16.self, at: offset + 6)
        let txn = data.readLE(UInt32.self, at: offset + 8)

        var container = PTPContainer(kind: kind, code: code, transactionID: txn)
        let bodyRange = (offset + 12)..<(offset + length)
        switch kind {
        case .command, .response, .event:
            var params: [UInt32] = []
            var i = bodyRange.lowerBound
            while i + 4 <= bodyRange.upperBound {
                params.append(data.readLE(UInt32.self, at: i))
                i += 4
            }
            container.parameters = params
        case .data:
            container.payload = data.subdata(in: bodyRange)
        }
        return (container, length)
    }

    /// ImageCaptureCore's passthrough returns a single blob that may be:
    /// data-phase payload with a response container appended, just a response
    /// container, or (observed on some stacks) raw payload only. This splits
    /// it into (payload, response). Instrument-heavy by design — Phase 0 needs
    /// to learn the exact shape on real hardware.
    public static func splitInboundBlob(_ blob: Data) -> (payload: Data, response: PTPContainer?) {
        // Fast path: whole blob is one response container.
        if let (c, len) = parse(blob), c.kind == .response, len == blob.count {
            return (Data(), c)
        }
        // Look for a trailing response container: try each plausible response
        // size (12 bytes + 0...5 params) anchored at the end of the blob.
        for paramCount in 0...5 {
            let size = 12 + paramCount * 4
            let start = blob.count - size
            guard start >= 0 else { break }
            if let (c, len) = parse(blob, at: start), c.kind == .response, len == size {
                return (blob.prefix(start), c)
            }
        }
        // No response container found — treat entire blob as payload.
        return (blob, nil)
    }
}

/// PTP response codes we care about.
public enum PTPResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let deviceBusy: UInt16 = 0x2019
    public static let operationNotSupported: UInt16 = 0x2005
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dest in
            self.copyBytes(to: dest, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: v)
    }
}

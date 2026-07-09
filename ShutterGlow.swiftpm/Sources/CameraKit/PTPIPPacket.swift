import Foundation

/// PTP/IP packet framing — CIPA DC-005, the published network transport for
/// PTP. Unlike Canon's own USB vendor extension (which needed real hardware
/// testing to pin down), these packet-type numbers and field layouts are a
/// formal spec with wide independent agreement (libgphoto2, libmtp, and
/// others all agree on these same values).
public enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case operationRequest = 6
    case operationResponse = 7
    case event = 8
    case startDataPacket = 9
    case dataPacket = 10
    case cancelTransaction = 11
    case endDataPacket = 12
    case ping = 13
    case pong = 14
}

public enum PTPIPDefaults {
    public static let port: UInt16 = 15740
}

/// One raw PTP/IP packet: 4-byte length (including this header) + 4-byte
/// type + payload. All fields little-endian.
public struct PTPIPPacket: Sendable {
    public let type: PTPIPPacketType
    public let payload: Data

    public init(type: PTPIPPacketType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: 8 + payload.count)
        data.appendLE(UInt32(8 + payload.count))
        data.appendLE(type.rawValue)
        data.append(payload)
        return data
    }
}

public enum PTPIPError: Error {
    case connectionFailed(String)
    case initFailed(String)
    case malformedPacket(String)
    case unexpectedPacketType(UInt32)
    case timeout(String)
}

public enum PTPIPCodec {
    /// Init Command Request payload: 16-byte GUID + UTF-16LE null-terminated
    /// friendly name + 4-byte version (minor u16, major u16).
    public static func initCommandRequestPayload(guid: [UInt8], friendlyName: String) -> Data {
        precondition(guid.count == 16, "GUID must be 16 bytes")
        var data = Data(guid)
        data.append(utf16leNullTerminated(friendlyName))
        data.appendLE(UInt16(0)) // version minor
        data.appendLE(UInt16(1)) // version major
        return data
    }

    /// Init Event Request payload: 4-byte connection number from Init Command Ack.
    public static func initEventRequestPayload(connectionNumber: UInt32) -> Data {
        var data = Data()
        data.appendLE(connectionNumber)
        return data
    }

    /// Operation Request payload: 4-byte dataphase (0=none,1=data-in,2=data-out)
    /// + 2-byte opcode + 4-byte transaction ID + up to 5 4-byte parameters.
    public static func operationRequestPayload(dataPhase: UInt32, opcode: UInt16,
                                                transactionID: UInt32, parameters: [UInt32]) -> Data {
        var data = Data()
        data.appendLE(dataPhase)
        data.appendLE(opcode)
        data.appendLE(transactionID)
        for p in parameters { data.appendLE(p) }
        return data
    }

    /// Start/End Data Packet payload: 4-byte transaction ID + 8-byte total
    /// length (start) or raw bytes (end).
    public static func startDataPacketPayload(transactionID: UInt32, totalLength: UInt64) -> Data {
        var data = Data()
        data.appendLE(transactionID)
        data.appendLE(totalLength)
        return data
    }

    public static func dataPacketPayload(transactionID: UInt32, chunk: Data) -> Data {
        var data = Data()
        data.appendLE(transactionID)
        data.append(chunk)
        return data
    }

    /// Parses an Operation Response payload: 2-byte response code + 4-byte
    /// transaction ID + trailing 4-byte parameters.
    public static func parseOperationResponse(_ payload: Data) -> (code: UInt16, transactionID: UInt32, parameters: [UInt32])? {
        guard payload.count >= 6 else { return nil }
        let code = payload.readLE(UInt16.self, at: 0)
        let txn = payload.readLE(UInt32.self, at: 2)
        var params: [UInt32] = []
        var offset = 6
        while offset + 4 <= payload.count {
            params.append(payload.readLE(UInt32.self, at: offset))
            offset += 4
        }
        return (code, txn, params)
    }

    /// Parses an Init Command Ack payload: 4-byte connection number + 16-byte
    /// camera GUID + UTF-16LE null-terminated camera name.
    public static func parseInitCommandAck(_ payload: Data) -> (connectionNumber: UInt32, cameraName: String)? {
        guard payload.count >= 20 else { return nil }
        let connectionNumber = payload.readLE(UInt32.self, at: 0)
        let name = readUTF16LEString(payload, from: 20)
        return (connectionNumber, name)
    }

    private static func utf16leNullTerminated(_ string: String) -> Data {
        var data = Data()
        for scalar in string.utf16 { data.appendLE(scalar) }
        data.appendLE(UInt16(0))
        return data
    }

    private static func readUTF16LEString(_ data: Data, from offset: Int) -> String {
        var units: [UInt16] = []
        var i = offset
        while i + 2 <= data.count {
            let unit = data.readLE(UInt16.self, at: i)
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

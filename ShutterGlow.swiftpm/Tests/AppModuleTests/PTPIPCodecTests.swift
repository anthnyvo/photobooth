import XCTest
@testable import CameraKit

final class PTPIPCodecTests: XCTestCase {

    // MARK: - Packet framing

    func testPacketEncoding() {
        let packet = PTPIPPacket(type: .initCommandRequest, payload: Data([1, 2, 3]))
        let data = packet.encoded()
        XCTAssertEqual(data.count, 11) // 8-byte header + 3-byte payload
        XCTAssertEqual(data.readLE(UInt32.self, at: 0), 11)
        XCTAssertEqual(data.readLE(UInt32.self, at: 4), PTPIPPacketType.initCommandRequest.rawValue)
    }

    func testEmptyPayloadPacket() {
        let packet = PTPIPPacket(type: .ping)
        XCTAssertEqual(packet.encoded().count, 8)
    }

    // MARK: - Operation request/response round trip

    func testOperationRequestPayloadLayout() {
        let payload = PTPIPCodec.operationRequestPayload(
            dataPhase: 1, opcode: 0x1001, transactionID: 42, parameters: [7, 8]
        )
        // 4 (dataPhase) + 2 (opcode) + 4 (txn) + 2*4 (params) = 18
        XCTAssertEqual(payload.count, 18)
        XCTAssertEqual(payload.readLE(UInt32.self, at: 0), 1)
        XCTAssertEqual(payload.readLE(UInt16.self, at: 4), 0x1001)
        XCTAssertEqual(payload.readLE(UInt32.self, at: 6), 42)
    }

    func testParseOperationResponse() {
        var payload = Data()
        payload.appendLE(UInt16(0x2001))
        payload.appendLE(UInt32(9))
        payload.appendLE(UInt32(100))
        payload.appendLE(UInt32(200))

        let parsed = PTPIPCodec.parseOperationResponse(payload)
        XCTAssertEqual(parsed?.code, 0x2001)
        XCTAssertEqual(parsed?.transactionID, 9)
        XCTAssertEqual(parsed?.parameters, [100, 200])
    }

    func testParseOperationResponseNoParameters() {
        var payload = Data()
        payload.appendLE(UInt16(0x2001))
        payload.appendLE(UInt32(1))
        let parsed = PTPIPCodec.parseOperationResponse(payload)
        XCTAssertEqual(parsed?.parameters, [])
    }

    func testParseOperationResponseTooShortReturnsNil() {
        XCTAssertNil(PTPIPCodec.parseOperationResponse(Data([1, 2, 3])))
    }

    // MARK: - Init Command Ack

    func testParseInitCommandAck() {
        var payload = Data()
        payload.appendLE(UInt32(5)) // connection number
        payload.append(Data(repeating: 0xAB, count: 16)) // 16-byte GUID, unread by parser
        for scalar in "EOS R".utf16 { payload.appendLE(scalar) }
        payload.appendLE(UInt16(0)) // null terminator

        let parsed = PTPIPCodec.parseInitCommandAck(payload)
        XCTAssertEqual(parsed?.connectionNumber, 5)
        XCTAssertEqual(parsed?.cameraName, "EOS R")
    }

    func testParseInitCommandAckEmptyName() {
        var payload = Data()
        payload.appendLE(UInt32(1))
        payload.append(Data(repeating: 0, count: 16))
        payload.appendLE(UInt16(0)) // immediate null terminator
        let parsed = PTPIPCodec.parseInitCommandAck(payload)
        XCTAssertEqual(parsed?.cameraName, "")
    }

    func testParseInitCommandAckTooShortReturnsNil() {
        XCTAssertNil(PTPIPCodec.parseInitCommandAck(Data(repeating: 0, count: 10)))
    }

    func testInitCommandRequestPayloadRoundTrip() {
        let guid = [UInt8](repeating: 0x42, count: 16)
        let payload = PTPIPCodec.initCommandRequestPayload(guid: guid, friendlyName: "iPad")
        // 16-byte GUID matches what we passed in.
        XCTAssertEqual([UInt8](payload.prefix(16)), guid)
    }
}

import XCTest
@testable import CameraKit

/// Pure parsing tests — run without hardware. Hardware truth still comes from
/// the spike app; these lock down the byte-level logic so on-device debugging
/// is only about what the camera actually sends.
final class PTPParsingTests: XCTestCase {

    func testCommandEncoding() {
        let c = PTPContainer(kind: .command, code: 0x9114, transactionID: 7, parameters: [1])
        let data = c.encoded()
        XCTAssertEqual(data.count, 16)
        XCTAssertEqual(data.readLE(UInt32.self, at: 0), 16)          // length
        XCTAssertEqual(data.readLE(UInt16.self, at: 4), 1)           // command
        XCTAssertEqual(data.readLE(UInt16.self, at: 6), 0x9114)      // code
        XCTAssertEqual(data.readLE(UInt32.self, at: 8), 7)           // txn
        XCTAssertEqual(data.readLE(UInt32.self, at: 12), 1)          // param
    }

    func testResponseRoundTrip() {
        let r = PTPContainer(kind: .response, code: 0x2001, transactionID: 9, parameters: [42])
        let parsed = PTPContainer.parse(r.encoded())
        XCTAssertEqual(parsed?.container.kind, .response)
        XCTAssertEqual(parsed?.container.code, 0x2001)
        XCTAssertEqual(parsed?.container.parameters, [42])
    }

    func testSplitInboundBlobPayloadPlusResponse() {
        var blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        blob.append(PTPContainer(kind: .response, code: 0x2001, transactionID: 3).encoded())
        let (payload, response) = PTPContainer.splitInboundBlob(blob)
        XCTAssertEqual(payload, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(response?.code, 0x2001)
    }

    func testSplitInboundBlobResponseOnly() {
        let blob = PTPContainer(kind: .response, code: 0x2019, transactionID: 3).encoded()
        let (payload, response) = PTPContainer.splitInboundBlob(blob)
        XCTAssertTrue(payload.isEmpty)
        XCTAssertEqual(response?.code, 0x2019)
    }

    func testSplitInboundBlobRawPayloadOnly() {
        let blob = Data(repeating: 0xAB, count: 100)
        let (payload, response) = PTPContainer.splitInboundBlob(blob)
        XCTAssertEqual(payload.count, 100)
        XCTAssertNil(response)
    }

    func testCanonEventRecordParsing() {
        var blob = Data()
        blob.appendLE(UInt32(16))                       // record length
        blob.appendLE(CanonEvent.objectAddedEx)         // type
        blob.append(Data([1, 2, 3, 4, 5, 6, 7, 8]))     // payload
        blob.appendLE(UInt32(8))                        // terminator
        blob.appendLE(UInt32(0))
        let records = CanonEventRecord.parse(blob)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].type, CanonEvent.objectAddedEx)
        XCTAssertEqual(records[0].payload.count, 8)
    }

    func testLiveViewStructuredFrame() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(repeating: 0, count: 50) + Data([0xFF, 0xD9])
        var blob = Data()
        blob.appendLE(UInt32(8 + jpeg.count))
        blob.appendLE(UInt32(1))                        // type 1 = JPEG
        blob.append(jpeg)
        guard case .frame(let out, let structured) = LiveViewParser.extractJPEG(blob) else {
            return XCTFail("no frame extracted")
        }
        XCTAssertTrue(structured)
        XCTAssertEqual(out, jpeg)
    }

    func testLiveViewFallbackScan() {
        // Garbage framing, but a JPEG buried inside.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1]) + Data(repeating: 7, count: 30) + Data([0xFF, 0xD9])
        let blob = Data(repeating: 0x99, count: 21) + jpeg + Data([0x00, 0x00])
        guard case .frame(let out, let structured) = LiveViewParser.extractJPEG(blob) else {
            return XCTFail("no frame extracted")
        }
        XCTAssertFalse(structured)
        XCTAssertEqual(out, jpeg)
    }
}

import XCTest
@testable import AppModule

/// Pure parsing tests — run without hardware, on CI's macOS runner via
/// `swift test`. Hardware truth still comes from real devices; these lock
/// down the byte-level logic so on-device debugging is only ever about what
/// the camera actually sends, not a framing bug in this code.
final class PTPContainerTests: XCTestCase {

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

    func testDataContainerRoundTrip() {
        let d = PTPContainer(kind: .data, code: 0x9116, transactionID: 3, payload: Data([1, 2, 3, 4, 5]))
        let parsed = PTPContainer.parse(d.encoded())
        XCTAssertEqual(parsed?.container.kind, .data)
        XCTAssertEqual(parsed?.container.payload, Data([1, 2, 3, 4, 5]))
    }

    func testParseRejectsTruncatedData() {
        XCTAssertNil(PTPContainer.parse(Data([1, 2, 3])))
    }

    func testParseRejectsUnknownKind() {
        var data = Data()
        data.appendLE(UInt32(12))
        data.appendLE(UInt16(99)) // not a valid Kind
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(0))
        XCTAssertNil(PTPContainer.parse(data))
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

    func testSplitInboundBlobResponseWithParameters() {
        // A response container with parameters is a different total size
        // than the zero-parameter case above — exercises the paramCount
        // search loop in splitInboundBlob rather than just its first guess.
        var blob = Data(repeating: 0x11, count: 20)
        blob.append(PTPContainer(kind: .response, code: 0x2001, transactionID: 5, parameters: [1, 2, 3]).encoded())
        let (payload, response) = PTPContainer.splitInboundBlob(blob)
        XCTAssertEqual(payload.count, 20)
        XCTAssertEqual(response?.parameters, [1, 2, 3])
    }

    // MARK: - Little-endian primitives

    func testAppendReadLERoundTrip() {
        var data = Data()
        data.appendLE(UInt16(0xBEEF))
        data.appendLE(UInt32(0xDEAD_C0DE))
        XCTAssertEqual(data.readLE(UInt16.self, at: 0), 0xBEEF)
        XCTAssertEqual(data.readLE(UInt32.self, at: 2), 0xDEAD_C0DE)
    }

    func testLittleEndianByteOrder() {
        var data = Data()
        data.appendLE(UInt32(0x0102_0304))
        // Little-endian: least significant byte first.
        XCTAssertEqual([UInt8](data), [0x04, 0x03, 0x02, 0x01])
    }

    // MARK: - Canon event records

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

    func testCanonEventRecordParsingMultipleRecords() {
        var blob = Data()
        for i: UInt32 in 1...3 {
            blob.appendLE(UInt32(12))
            blob.appendLE(i)
            blob.append(Data([UInt8(i)]))
        }
        blob.appendLE(UInt32(8)) // terminator
        blob.appendLE(UInt32(0))
        let records = CanonEventRecord.parse(blob)
        XCTAssertEqual(records.map(\.type), [1, 2, 3])
    }

    func testCanonEventRecordParsingEmptyBlob() {
        XCTAssertTrue(CanonEventRecord.parse(Data()).isEmpty)
    }

    // MARK: - Canon live view framing

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

    func testLiveViewNoFrame() {
        guard case .noFrame = LiveViewParser.extractJPEG(Data(repeating: 0, count: 10)) else {
            return XCTFail("expected no frame in garbage-only blob")
        }
    }
}

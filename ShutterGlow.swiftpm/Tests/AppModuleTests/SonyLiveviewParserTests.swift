import XCTest
@testable import CameraKit

final class SonyLiveviewParserTests: XCTestCase {

    /// Builds one valid Sony liveview chunk: 8-byte common header (only the
    /// payload type at byte 1 matters to the parser) + 128-byte payload
    /// header (start code + 3-byte big-endian size + 1-byte padding) + JPEG
    /// + padding.
    private func makeChunk(payloadType: UInt8, jpeg: Data, padding: Int = 0) -> Data {
        var chunk = Data([0xFF, payloadType]) + Data(repeating: 0, count: 6) // common header
        var header = Data([0x24, 0x35, 0x68, 0x79])
        let size = jpeg.count
        header.append(contentsOf: [
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
            UInt8(padding),
        ])
        header.append(Data(repeating: 0, count: 128 - header.count))
        chunk.append(header)
        chunk.append(jpeg)
        chunk.append(Data(repeating: 0, count: padding))
        return chunk
    }

    func testParsesImageFrame() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let chunk = makeChunk(payloadType: 0x01, jpeg: jpeg)
        let (frame, consumed) = SonyLiveviewParser.nextFrame(in: chunk) ?? (nil, 0)
        XCTAssertEqual(frame, jpeg)
        XCTAssertEqual(consumed, chunk.count)
    }

    func testSkipsNonImagePayloadType() {
        let chunk = makeChunk(payloadType: 0x02, jpeg: Data([1, 2, 3]))
        let (frame, consumed) = SonyLiveviewParser.nextFrame(in: chunk) ?? (nil, 0)
        XCTAssertNil(frame)
        XCTAssertEqual(consumed, chunk.count)
    }

    func testAccountsForPadding() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let chunk = makeChunk(payloadType: 0x01, jpeg: jpeg, padding: 5)
        let (frame, consumed) = SonyLiveviewParser.nextFrame(in: chunk) ?? (nil, 0)
        XCTAssertEqual(frame, jpeg)
        XCTAssertEqual(consumed, chunk.count) // includes the 5 padding bytes
    }

    func testIncompleteBufferReturnsNil() {
        let chunk = makeChunk(payloadType: 0x01, jpeg: Data(repeating: 0xAA, count: 50))
        // Cut the buffer short mid-JPEG — not enough bytes for a full frame yet.
        let truncated = chunk.prefix(chunk.count - 10)
        XCTAssertNil(SonyLiveviewParser.nextFrame(in: Data(truncated)))
    }

    func testResyncsPastGarbageBeforeStartCode() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let garbage = Data([0x01, 0x02, 0x03])
        let buffer = garbage + makeChunk(payloadType: 0x01, jpeg: jpeg)
        let (frame, consumed) = SonyLiveviewParser.nextFrame(in: buffer) ?? (nil, 0)
        // First call resyncs past the garbage but doesn't necessarily also
        // parse the frame in one step — feed the consumed bytes back in,
        // same as the real buffer-draining loop in SonyCamera does.
        if let frame {
            XCTAssertEqual(frame, jpeg)
        } else {
            let (frame2, _) = SonyLiveviewParser.nextFrame(in: buffer.dropFirst(consumed)) ?? (nil, 0)
            XCTAssertEqual(frame2, jpeg)
        }
    }

    func testEmptyBufferReturnsNil() {
        XCTAssertNil(SonyLiveviewParser.nextFrame(in: Data()))
    }

    func testNoStartByteConsumesWholeBuffer() {
        let buffer = Data(repeating: 0x00, count: 10)
        let (frame, consumed) = SonyLiveviewParser.nextFrame(in: buffer) ?? (nil, -1)
        XCTAssertNil(frame)
        XCTAssertEqual(consumed, buffer.count)
    }
}

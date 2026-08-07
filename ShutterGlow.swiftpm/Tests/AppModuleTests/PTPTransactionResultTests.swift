import XCTest
@testable import CameraKit

/// The two-blob assembly that ImageCaptureCore's passthrough requires.
///
/// This is the highest-consequence dozen lines in the transport layer. Reading
/// the wrong blob here did not fail loudly — it returned a clean `0x2001` OK
/// with an empty payload, which reads as "the camera had nothing to send"
/// rather than "we looked in the wrong place". That misreading was recorded as
/// an iOS platform limitation, and an entire Wi-Fi transport was built around
/// it before a hardware test found a 184KB JPEG in the parameter being thrown
/// away.
///
/// So these tests use the **real byte shapes captured off the EOS R on
/// 2026-08-01**, not invented ones, and assert the payload is non-empty. A
/// regression here would be silent again.
final class PTPTransactionResultTests: XCTestCase {

    /// Verbatim from the hardware log: a 20-byte response container, code
    /// 0x2001, transaction 1680, two parameters. This is the entire second
    /// blob — note there is no room in it for a 184KB image.
    private let realResponseBlob = Data([
        0x14, 0x00, 0x00, 0x00, // length 20
        0x03, 0x00,             // kind 3 = response
        0x01, 0x20,             // code 0x2001 = OK
        0x90, 0x06, 0x00, 0x00, // transaction 1680
        0x00, 0x00, 0x00, 0x00, // param 0
        0x99, 0xEE, 0x02, 0x00, // param 0x0002EE99
    ])

    /// Head of the real first blob: Canon live-view block framing
    /// ({u32 length, u32 type, data...}), NOT a PTP container — the hardware
    /// log reported "does NOT parse as one". Block type 1 carries the JPEG.
    private func realDataPhase(jpeg: Data) -> Data {
        var blob = Data()
        blob.appendLE(UInt32(8 + jpeg.count))
        blob.appendLE(UInt32(1))
        blob.append(jpeg)
        return blob
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0xFF, 0xD9])

    // MARK: - The bug

    func testPayloadComesFromTheDataPhaseNotTheResponseBlob() {
        // The exact shape that used to yield an empty payload every frame.
        let result = PTPTransactionResult.from(dataPhase: realDataPhase(jpeg: jpeg),
                                               responseBlob: realResponseBlob)

        XCTAssertFalse(result.payload.isEmpty,
                       "payload must carry the data phase — an empty payload here is the original bug")
        XCTAssertEqual(result.response?.code, PTPResponseCode.ok)
        XCTAssertEqual(result.response?.transactionID, 1680)
    }

    func testLiveViewParserGetsAFrameOutOfTheAssembledPayload() {
        // End to end through the same path EOSCamera uses, because "payload is
        // non-empty" is not the same claim as "a frame comes out of it".
        let result = PTPTransactionResult.from(dataPhase: realDataPhase(jpeg: jpeg),
                                               responseBlob: realResponseBlob)

        guard case .frame(let decoded, let viaFraming) = LiveViewParser.extractJPEG(result.payload) else {
            return XCTFail("no frame decoded from the assembled payload")
        }
        XCTAssertEqual(decoded, jpeg)
        XCTAssertTrue(viaFraming, "should decode via Canon block framing, not the SOI/EOI fallback scan")
    }

    // MARK: - Not breaking what already worked

    func testCommandWithNoDataPhaseBehavesExactlyAsBefore() {
        // Capture and SetRemoteMode were never broken over USB. They return a
        // response and no data, and this fix must leave them alone rather than
        // "repairing" them into some new shape.
        let result = PTPTransactionResult.from(dataPhase: Data(), responseBlob: realResponseBlob)

        XCTAssertTrue(result.payload.isEmpty)
        XCTAssertEqual(result.response?.code, PTPResponseCode.ok)
    }

    func testFallsBackToSplittingTheResponseBlobWhenThereIsNoDataPhase() {
        // Guards the case where a reply arrives as payload+response in ONE
        // blob. Without the fallback this path would silently return nothing,
        // which is the same failure mode being fixed, just relocated.
        var combined = realDataPhase(jpeg: jpeg)
        combined.append(realResponseBlob)

        let result = PTPTransactionResult.from(dataPhase: Data(), responseBlob: combined)

        XCTAssertFalse(result.payload.isEmpty)
        XCTAssertEqual(result.response?.code, PTPResponseCode.ok)
        if case .noFrame = LiveViewParser.extractJPEG(result.payload) {
            XCTFail("combined-blob fallback lost the frame")
        }
    }

    func testBothBlobsEmptyIsNotACrash() {
        let result = PTPTransactionResult.from(dataPhase: Data(), responseBlob: Data())

        XCTAssertTrue(result.payload.isEmpty)
        XCTAssertNil(result.response)
    }

    // MARK: - Diagnostic passthrough

    func testRawFirstParamStillCarriesTheUntouchedDataPhase() {
        // PassthroughDiagnostic reports on this. If the fix ever regresses,
        // that diagnostic is how it gets found again, so it must not be
        // quietly repointed at the assembled payload.
        let dataPhase = realDataPhase(jpeg: jpeg)
        let result = PTPTransactionResult.from(dataPhase: dataPhase, responseBlob: realResponseBlob)

        XCTAssertEqual(result.rawFirstParam, dataPhase)
        XCTAssertEqual(result.rawInbound, realResponseBlob)
    }
}

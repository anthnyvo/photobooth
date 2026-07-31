import XCTest
@testable import CameraKit

/// The diagnostic that decides whether USB live view is reachable at all.
///
/// Worth testing rather than eyeballing on hardware because a bench test gets
/// run once, on a borrowed evening, and its output is the thing an
/// architecture decision hangs on. Phase 0 already made this mistake once: it
/// read one of the passthrough's two data blobs, saw a bare 0x2001, concluded
/// "iOS platform limitation", and the entire Wi-Fi transport was built on that
/// conclusion. A describer that quietly reported "no frame" for a blob that
/// does contain one would send us down that road a second time.
///
/// So each test below feeds in a blob whose contents are known exactly, and
/// asserts the verdict a person will actually read off the iPad screen.
final class PassthroughDiagnosticTests: XCTestCase {

    /// A minimal but structurally valid JPEG: SOI ... EOI.
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0xFF, 0xD9])

    /// Canon's GetViewFinderData framing: { u32 blockLength, u32 blockType,
    /// data... }, blockType 1 = the live view JPEG.
    private func canonFramedLiveView(_ payload: Data) -> Data {
        var blob = Data()
        blob.appendLE(UInt32(8 + payload.count))
        blob.appendLE(UInt32(1))
        blob.append(payload)
        return blob
    }

    /// Exactly what Phase 0 recorded seeing: a 12-byte response container,
    /// code 0x2001 (OK), carrying no payload at all.
    private func bareOKResponse(transactionID: UInt32 = 1) -> Data {
        PTPContainer(kind: .response, code: PTPResponseCode.ok,
                     transactionID: transactionID).encoded()
    }

    // MARK: - describe

    func testBareOKResponseIsReportedAsAResponseWithNoFrame() {
        let text = PassthroughDiagnostic.describe("param 2", bareOKResponse())

        // The three facts that together mean "this blob is the response, not
        // the data phase" — the exact reading Phase 0 got wrong.
        XCTAssertTrue(text.contains("kind=response"), text)
        XCTAssertTrue(text.contains("code=0x2001"), text)
        XCTAssertTrue(text.contains("fills blob"), text)
        XCTAssertTrue(text.contains("no JPEG SOI"), text)
        XCTAssertTrue(text.contains("LiveViewParser: no frame"), text)
    }

    func testCanonFramedLiveViewBlobIsReportedAsAFrame() {
        let text = PassthroughDiagnostic.describe("param 1", canonFramedLiveView(jpeg))

        XCTAssertTrue(text.contains("JPEG SOI found"), text)
        XCTAssertTrue(text.contains("EXTRACTED"), text)
        // Structured framing, not the SOI/EOI fallback scan — tells us the
        // EOS R's real block format matches what LiveViewParser expects.
        XCTAssertTrue(text.contains("structured framing"), text)
    }

    func testEmptyBlobSaysSoRatherThanLookingLikeAFailedParse() {
        // A discarded parameter that is genuinely empty and one that holds an
        // unparseable blob mean completely different things for next steps.
        XCTAssertTrue(PassthroughDiagnostic.describe("param 1", Data()).contains("EMPTY"))
    }

    func testNonContainerBlobIsNotSilentlyReportedAsAContainer() {
        // A raw payload with no PTP header must not be dressed up as a
        // container — that would invent structure that isn't there.
        let text = PassthroughDiagnostic.describe("param 1", Data([0x01, 0x02, 0x03]))

        XCTAssertTrue(text.contains("does NOT parse as one"), text)
    }

    // MARK: - verdict

    /// The whole reason this diagnostic exists. If the hardware produces this
    /// shape, Phase 0's conclusion is wrong and USB live view is available.
    func testFrameInFirstParamBlamesTheDiscardedParameter() {
        let verdict = PassthroughDiagnostic.verdict(
            firstParam: canonFramedLiveView(jpeg),
            secondParam: bareOKResponse())

        XCTAssertTrue(verdict.contains("FIRST parameter"), verdict)
        XCTAssertTrue(verdict.contains("discards"), verdict)
    }

    func testFrameInSecondParamPointsAtSetupRatherThanTheParameterSplit() {
        // If the frame is where we already read, the parameter theory is dead
        // and the fault is upstream (opcode params, EVF mode not set).
        let verdict = PassthroughDiagnostic.verdict(
            firstParam: bareOKResponse(),
            secondParam: canonFramedLiveView(jpeg))

        XCTAssertTrue(verdict.contains("SECOND parameter"), verdict)
    }

    func testNoFrameAnywhereEscalatesInsteadOfDeclaringPlatformDefeat() {
        // Phase 0's failure mode was concluding "impossible" too early. Even
        // the all-negative verdict has to point somewhere actionable, because
        // Cascable demonstrably ships USB live view on iPadOS for Canon EOS.
        let verdict = PassthroughDiagnostic.verdict(
            firstParam: bareOKResponse(),
            secondParam: bareOKResponse())

        XCTAssertTrue(verdict.contains("no JPEG in either"), verdict)
        XCTAssertTrue(verdict.contains("Cascable"), verdict)
    }

    func testFrameInBothParamsStillGivesAnUnambiguousInstruction() {
        let blob = canonFramedLiveView(jpeg)
        let verdict = PassthroughDiagnostic.verdict(firstParam: blob, secondParam: blob)

        XCTAssertTrue(verdict.contains("BOTH"), verdict)
    }
}

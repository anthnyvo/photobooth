import Foundation

/// Describes the shape of a raw blob coming back from ImageCaptureCore's PTP
/// passthrough, so we can tell — on hardware, from a log — which of the
/// completion handler's two NSData parameters carries what.
///
/// Why this exists: `requestSendPTPCommand(_:outData:completion:)` hands back
/// TWO data blobs, and ICCTransport has always read the second one and thrown
/// the first away with `_`. Phase 0 concluded from that second blob ("a clean
/// 0x2001 response with a 0-byte payload") that iOS never surfaces the
/// device-to-host bulk data phase, and the whole Wi-Fi transport was built on
/// that conclusion. But a 12-byte 0x2001 container with no payload is exactly
/// what a PTP *response* looks like when the *data phase* arrived separately —
/// i.e. in the parameter we discarded. Cascable ships USB live view on
/// iPadOS for Canon EOS, so the platform clearly permits it; the limitation is
/// far more likely ours than Apple's.
///
/// This makes no assumption about which parameter is which. It reports both
/// and lets the hardware answer.
public enum PassthroughDiagnostic {

    /// A human-readable, log-pasteable anatomy of one blob.
    public static func describe(_ label: String, _ data: Data) -> String {
        guard !data.isEmpty else { return "\(label): EMPTY (0 bytes)" }

        var lines = ["\(label): \(data.count) bytes"]
        lines.append("  head: \(hexPrefix(data, 24))")

        // Does it parse as a PTP container, and does that container account
        // for the whole blob? A response container that exactly fills the blob
        // means this parameter is the response, not the data phase.
        if let (container, length) = PTPContainer.parse(data) {
            let kind = String(describing: container.kind)
            let fills = length == data.count ? "fills blob" : "\(length) of \(data.count) bytes"
            let params = container.parameters.map { "0x" + hex($0, width: 8) }.joined(separator: ", ")
            // Interpolation rather than String(format:): the fields here are
            // UInt16 and UInt32, and %X/%u promote CVarArg by platform word
            // size, which is exactly the kind of detail that silently prints
            // a wrong opcode in the one log this decision rests on.
            lines.append("  PTP container: kind=\(kind) code=0x\(hex(container.code, width: 4))"
                         + " txn=\(container.transactionID) (\(fills))")
            if !params.isEmpty { lines.append("  container params: [\(params)]") }
        } else {
            lines.append("  PTP container: does NOT parse as one — raw payload?")
        }

        // The actual question: is there a JPEG in here?
        if let soi = data.firstRange(of: Data([0xFF, 0xD8, 0xFF])) {
            let offset = data.distance(from: data.startIndex, to: soi.lowerBound)
            lines.append("  *** JPEG SOI found at offset \(offset) ***")
        } else {
            lines.append("  no JPEG SOI (FF D8 FF) anywhere in this blob")
        }

        // And does the Canon live-view framing parser get a frame out of it?
        switch LiveViewParser.extractJPEG(data) {
        case .frame(let jpeg, let viaFraming):
            lines.append("  *** LiveViewParser EXTRACTED a \(jpeg.count)-byte frame "
                         + "(\(viaFraming ? "structured framing" : "SOI/EOI scan")) ***")
        case .noFrame:
            lines.append("  LiveViewParser: no frame")
        }

        return lines.joined(separator: "\n")
    }

    /// The one line worth reading in the log. Answers the actual question
    /// rather than making whoever runs the test interpret two blob dumps.
    public static func verdict(firstParam: Data, secondParam: Data) -> String {
        let firstHasFrame = hasFrame(firstParam)
        let secondHasFrame = hasFrame(secondParam)

        switch (firstHasFrame, secondHasFrame) {
        case (true, false):
            return """
            VERDICT: live view data is in the FIRST parameter — the one \
            ICCTransport.send() currently discards with `_`. Phase 0's \
            "iOS can't do USB live view" conclusion is wrong, and the fix is \
            to read that parameter instead. USB live view is available.
            """
        case (false, true):
            return """
            VERDICT: live view data is in the SECOND parameter, which is \
            already what we read. Something else is wrong — check the opcode \
            params (EOS Utility uses 0x00200000, 0, 0) and that EVFMode and \
            EVFOutputDevice were set first.
            """
        case (true, true):
            return "VERDICT: BOTH parameters contain a frame. Read the first; log the shapes above."
        case (false, false):
            return """
            VERDICT: no JPEG in either parameter. The data phase really may not \
            be reachable this way — next step is Cascable's SDK (30-day eval), \
            which ships USB live view on iPadOS for Canon EOS. Check the shapes \
            above: if BOTH blobs are bare 0x2001 responses, the data phase is \
            being dropped by ImageCaptureCore, not misread by us.
            """
        }
    }

    private static func hasFrame(_ data: Data) -> Bool {
        if case .frame = LiveViewParser.extractJPEG(data) { return true }
        return false
    }

    private static func hexPrefix(_ data: Data, _ count: Int) -> String {
        data.prefix(count).map { hex($0, width: 2) }.joined(separator: " ")
    }

    private static func hex<T: BinaryInteger>(_ value: T, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

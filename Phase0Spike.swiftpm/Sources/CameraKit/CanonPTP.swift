import Foundation

/// Canon EOS vendor-extension PTP constants.
/// Reference: libgphoto2 camlibs/ptp2/ptp.h (the de-facto public documentation
/// of Canon's PTP extension) and Julian Schroden's PTP/IP write-ups.
public enum CanonOp {
    // Session / mode
    public static let setRemoteMode: UInt16 = 0x9114        // param: 1 = enable remote control
    public static let setEventMode: UInt16 = 0x9115         // param: 1 = enable event reporting
    public static let getEvent: UInt16 = 0x9116             // poll; data phase = event records

    // Capture
    public static let remoteRelease: UInt16 = 0x910F        // simple full release (older bodies)
    public static let remoteReleaseOn: UInt16 = 0x9128      // params: (1|2, 0) — 1 = half, 2 = full
    public static let remoteReleaseOff: UInt16 = 0x9129     // params: (1|2)

    // Live view
    public static let getViewFinderData: UInt16 = 0x9153    // params observed from EOS Utility: (0x00200000, 0, 0)

    // Properties
    public static let setDevicePropValueEx: UInt16 = 0x9110 // data phase: u32 size, u32 propCode, value
    public static let getDevicePropValue: UInt16 = 0x9127

    // Object transfer (spike uses ImageCaptureCore's own download instead;
    // these are here for the Phase 1 direct-transfer path)
    public static let getPartialObject: UInt16 = 0x9107
    public static let transferComplete: UInt16 = 0x9117
}

/// Standard (vendor-neutral) PTP opcodes needed for object download over
/// PTP/IP — USB capture retrieval goes through ImageCaptureCore's own file
/// APIs instead, so these were never needed there.
public enum StandardPTPOp {
    public static let openSession: UInt16 = 0x1002
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
}

/// Standard (vendor-neutral) PTP event codes, delivered over PTP/IP's
/// dedicated event connection — a separate mechanism from Canon's own
/// GetEvent command-response polling used on the command connection.
public enum StandardPTPEvent {
    public static let objectAdded: UInt16 = 0x4002
}

public enum CanonProp {
    public static let evfOutputDevice: UInt32 = 0xD1B0  // 0 = none, 1 = camera TFT, 2 = PC
    public static let evfMode: UInt32 = 0xD1B3          // 1 = enable EVF
    public static let captureDestination: UInt32 = 0xD11C
    /// Route captures to the host instead of the memory card. Per libgphoto2
    /// (ptp.h: PTP_CANON_EOS_CAPTUREDEST_HD). Skipping this is a documented
    /// cause of capture-time errors (Err 70 et al.) on EOS bodies during
    /// third-party tethering — the camera also tries to write the card mid-
    /// capture, and any card hiccup surfaces as a body-halting error.
    public static let captureDestinationHost: UInt32 = 4
    /// 3 = manual focus. libgphoto2 checks this before deciding whether to
    /// wait for AF confirmation at all — worth knowing which mode the body
    /// is actually in during capture debugging, not just what a switch
    /// looked like from outside.
    public static let focusMode: UInt32 = 0xD108
    public static let iso: UInt32 = 0xD103
    public static let whiteBalance: UInt32 = 0xD109
    public static let exposureCompensation: UInt32 = 0xD104
    public static let flashCompensation: UInt32 = 0xD105
}

public enum CanonEvent {
    public static let objectAddedEx: UInt32 = 0xC181
    public static let objectRemoved: UInt32 = 0xC182
    public static let propValueChanged: UInt32 = 0xC189
    public static let availListChanged: UInt32 = 0xC18A
    public static let objectAddedEx64: UInt32 = 0xC1A7  // newer bodies report adds with this
    /// Fires instead of ObjectAddedEx when CaptureDestination=Host (SDRAM):
    /// the image was never written to the card, so the card-object-added
    /// events never come — this is Canon's own signal that a host-destined
    /// capture is ready to transfer.
    public static let requestObjectTransfer: UInt32 = 0xC186
    /// Carries focus-confirm data during a half-press (libgphoto2:
    /// PTP_EC_CANON_EOS_OLCInfoChanged). Never observed in this app's logs
    /// yet — our event loop is cancelled before triggerShutter() ever runs,
    /// so we've never actually polled GetEvent during the one window this
    /// fires in. If it never shows up even now, AF genuinely isn't running.
    public static let olcInfoChanged: UInt32 = 0xC1A5
}

/// One record parsed out of a Canon GetEvent data blob.
/// Blob layout: repeated { u32 recordLength, u32 eventType, payload... },
/// terminated by a record with length 8 and type 0.
public struct CanonEventRecord: Sendable {
    public let type: UInt32
    public let payload: Data

    public static func parse(_ blob: Data) -> [CanonEventRecord] {
        var records: [CanonEventRecord] = []
        var offset = 0
        while offset + 8 <= blob.count {
            let length = Int(blob.readLE(UInt32.self, at: offset))
            let type = blob.readLE(UInt32.self, at: offset + 4)
            guard length >= 8, offset + length <= blob.count else { break }
            if type == 0 { break } // terminator
            records.append(CanonEventRecord(
                type: type,
                payload: blob.subdata(in: (blob.startIndex + offset + 8)..<(blob.startIndex + offset + length))
            ))
            offset += length
        }
        return records
    }
}

/// Parses a GetViewFinderData payload into JPEG frames.
/// Blob layout: repeated { u32 blockLength, u32 blockType, data... };
/// blockType 1 = JPEG live view image. Falls back to scanning for the JPEG
/// SOI/EOI markers if the framing doesn't match what the EOS R actually sends
/// — Phase 0 should log which path fired.
public enum LiveViewParser {
    public enum Result: Sendable {
        case frame(Data, viaFraming: Bool)
        case noFrame
    }

    public static func extractJPEG(_ blob: Data) -> Result {
        // Structured path
        var offset = 0
        while offset + 8 <= blob.count {
            let length = Int(blob.readLE(UInt32.self, at: offset))
            let type = blob.readLE(UInt32.self, at: offset + 4)
            guard length >= 8, offset + length <= blob.count else { break }
            if type == 1 {
                let jpeg = blob.subdata(in: (blob.startIndex + offset + 8)..<(blob.startIndex + offset + length))
                if jpeg.starts(with: [0xFF, 0xD8]) {
                    return .frame(jpeg, viaFraming: true)
                }
            }
            offset += length
        }
        // Fallback: scan for SOI ... EOI
        if let soi = blob.firstRange(of: Data([0xFF, 0xD8, 0xFF])),
           let eoi = blob.lastRange(of: Data([0xFF, 0xD9])),
           soi.lowerBound < eoi.upperBound {
            return .frame(blob.subdata(in: soi.lowerBound..<eoi.upperBound), viaFraming: false)
        }
        return .noFrame
    }
}

import Foundation

/// Sony vendor PTP constants.
///
/// Sourced from libgphoto2's `camlibs/ptp2/ptp.h`, the same reference the
/// Canon constants came from. Sony's extension is a "SDIO" layer bolted on
/// top of standard PTP: the body accepts almost nothing until a three-step
/// connect handshake has run, which is the single biggest difference from
/// Canon and the thing that makes a naive PTP client look like it does not
/// work at all.
public enum SonyOp {
    /// The handshake. Called three times with a rising first parameter —
    /// see SonyPTPCamera.enterRemoteMode for the order and why.
    public static let sdioConnect: UInt16 = 0x9201
    /// Returns the vendor property/opcode lists. libgphoto2 calls this
    /// between connect steps 2 and 3, and the body expects that ordering.
    public static let sdioGetExtDeviceInfo: UInt16 = 0x9202
    public static let getDevicePropDesc: UInt16 = 0x9203
    public static let getDevicePropValue: UInt16 = 0x9204
    public static let sdioSetExtDevicePropValue: UInt16 = 0x9205
    public static let getControlDeviceDesc: UInt16 = 0x9206
    /// Press/release the virtual shutter buttons — Sony's equivalent of
    /// Canon's RemoteReleaseOn/Off.
    public static let sdioControlDevice: UInt16 = 0x9207
    /// One call returning every property's current value. Sony has no
    /// per-property read that is cheap, so this is how state is polled.
    public static let sdioGetAllExtDevicePropInfo: UInt16 = 0x9209
    /// Sony's chunked object read. Candidate route for live view frames —
    /// unverified, see SonyPTPCamera.startLiveView.
    public static let sdioGetPartialLargeObject: UInt16 = 0x9211
}

public enum SonyProp {
    /// Half-press equivalent. Enumerated [1, 2]; 2 engages, 1 releases.
    public static let autofocus: UInt32 = 0xD2C1
    /// Full press. Same [1, 2] encoding.
    public static let capture: UInt32 = 0xD2C2
}

/// Object handles Sony reserves for things that are not files on the card.
public enum SonyObject {
    /// The live view frame, in the widely-used reverse-engineered mapping.
    ///
    /// **UNVERIFIED.** Every other constant in this file traces to
    /// libgphoto2's headers; this one does not, and no primary source for it
    /// was found. It is a candidate, not a fact, and `startLiveView` treats it
    /// as one — it tries several routes and reports which the body actually
    /// honours rather than assuming this is right. That pattern is what found
    /// the Canon bug on 2026-08-03 after four wrong theories.
    public static let liveViewFrame: UInt32 = 0xFFFF_C002
}

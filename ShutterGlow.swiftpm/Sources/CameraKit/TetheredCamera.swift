import Foundation

/// What the booth needs from any tethered camera — the abstraction that
/// lets BoothViewModel run Canon, Nikon, or a generic PTP body through the
/// exact same guest flow. EOSCamera (proven on the EOS R) is the reference
/// implementation; other brands conform with their own vendor opcodes.
public protocol TetheredCamera: Actor {
    /// Vendor session setup after the transport reports ready — remote
    /// mode, event mode, whatever the body needs before it obeys commands.
    func enterRemoteMode() async throws
    /// Live-view JPEGs. Implementations without a live-view protocol
    /// return a stream that finishes immediately — the booth runs without
    /// a feed (no AR props/animations, capture still works).
    func startLiveView() async throws -> AsyncStream<Data>
    /// Fire the shutter and return the resulting image bytes.
    func capturePhoto() async throws -> Data
    /// Battery updates, if the body ever reports one. Optional to honor.
    func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void)
    func disconnect()
}

/// Guest-facing camera brand choice on the connect screen. Canon (Wi-Fi
/// PTP/IP) and USB Webcam (UVC) are both verified on hardware. Sony's
/// legacy HTTP API, Nikon/Fujifilm/generic-PTP support exist in CameraKit
/// but Sony's is untested and the rest are deliberately not offered here
/// right now — pruned down to just the brands actually in use/under test.
public enum CameraBrand: String, CaseIterable, Sendable, Identifiable {
    case canonEOS
    case sony
    case usbWebcam

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .canonEOS: "Canon EOS"
        case .sony: "Sony"
        case .usbWebcam: "USB Webcam"
        }
    }

    public var connectionHint: String {
        switch self {
        case .canonEOS:
            "Camera in Remote control (EOS Utility) Wi-Fi mode."
        case .sony:
            "Camera in Control with Smartphone / Smart Remote mode, iPad joined to the camera's Wi-Fi. Uses Sony's legacy Camera Remote API, which only older α and RX bodies support. Not yet verified on hardware. If you have a recent Sony such as the a7 IV, use USB Webcam instead: that path is tested and runs over a single cable."
        // Body list verified against vendor documentation 2026-08-01. Check a
        // vendor manual before adding OR removing anything here — this list
        // is bought off, and both directions of error cost an operator money.
        //
        // Cautionary tale, since it happened twice in one day. A Panasonic
        // "L10" was listed and is not a Lumix; removed. A Canon "R6 V" was
        // listed, assumed invented on the same basis, and removed — wrongly.
        // The EOS R6 V is real (announced 2026-05-13, and Canon publishes a
        // UVC streaming page for it), it was simply newer than the knowledge
        // it was checked against. Restored. Absence from memory is not
        // evidence a body does not exist; only a vendor page is.
        //
        // The gate is NATIVE UVC, not "can be a webcam": Canon's EOS Webcam
        // Utility, Nikon's Webcam Utility and Fujifilm's X Webcam are all
        // desktop apps and are useless to an iPad, so bodies that need them
        // do not belong here. Fujifilm's cut-off is X-Processor 5; Panasonic
        // list G9 II and GH7 as planned rather than shipping, so both are
        // deliberately absent.
        case .usbWebcam:
            "Camera in USB Streaming/UVC webcam mode, wired to the iPad over USB-C. Verified working on a Sony a7 IV. Not Sony-specific: works with any camera whose firmware supports native UVC, including other Sony (a7 V, a7R V, ZV-1, ZV-1F, ZV-E10, FX30), Canon EOS (R1, R5 II, R6 II/III/V, R8, R50, R50 V), Nikon (Zf, Z5 II, Z50 II, Z6 III, ZR), Fujifilm (X100VI, X-E5, X-H2/H2S, X-M5, X-S20, X-T30 III, X-T5, X-T50) and Panasonic Lumix (S1 II, S1R II, S1 IIE). Not GoPro, which uses a proprietary protocol instead of standard UVC. No IP needed, just plug in and tap Connect. Live view and capture both come from the video feed rather than the shutter, so there is no hot-shoe flash sync and photo resolution is capped at the stream resolution, not the sensor's full still resolution."
        }
    }

    private static let storageKey = "com.anthonyvo.shutterglow.cameraBrand"

    public static func loadSaved() -> CameraBrand {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(CameraBrand.init(rawValue:)) ?? .canonEOS
    }

    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

extension EOSCamera: TetheredCamera {}

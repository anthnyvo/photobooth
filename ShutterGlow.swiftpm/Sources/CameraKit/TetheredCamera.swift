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
    /// Hand the camera back. Async because a correct teardown is ordered -
    /// EOSCamera restores properties it changed and waits for them to land,
    /// since a body left reconfigured writes photos nowhere.
    func disconnect() async

    /// Stop pulling frames without ending the session, for a wired camera
    /// kept alive while nobody is watching the feed (the operator stepped
    /// back to the event list). The body stays in live-view mode.
    func pauseLiveView() async
    /// Hand back a fresh frame stream on a body that is already streaming,
    /// undoing `pauseLiveView()`. Distinct from `startLiveView()` because
    /// the session never dropped: no mode properties get re-sent and there
    /// is no sensor settle time to wait out.
    func resumeLiveView() async throws -> AsyncStream<Data>
}

public extension TetheredCamera {
    /// Default for drivers with no separate poll loop to suspend (UVC, and
    /// the PTP bodies whose live view is a probe that has not been proven on
    /// hardware). Pausing is an optimisation; resuming has to work, so it
    /// falls back to a full start.
    func pauseLiveView() async {}
    func resumeLiveView() async throws -> AsyncStream<Data> {
        try await startLiveView()
    }
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
            "Plug the camera in with a USB-C cable and it connects on its own — no network, no IP, nothing to set. Any camera speaking PTP works over the cable, though only Canon EOS is hardware-proven; other bodies may capture without a live preview. If no cable is found this falls back to Wi-Fi, which is Canon-only and needs the camera in Remote control (EOS Utility) mode."
        case .sony:
            "Camera in Control with Smartphone / Smart Remote mode, iPad joined to the camera's Wi-Fi. Uses Sony's legacy Camera Remote API, which only older α and RX bodies support. Not yet verified on hardware. If you have a recent Sony such as the a7 IV, use USB Webcam instead: that path is tested and runs over a single cable."
        case .usbWebcam:
            "Camera in USB Streaming/UVC webcam mode, wired to the iPad over USB-C. Verified working on a Sony a7 IV. Not Sony-specific: works with any camera whose firmware supports native UVC, including recent Canon EOS (R1, R5 II, R6 II/III/V, R8, R50), Nikon (Z5 II, Z50 II, ZR, Z6 III), Fujifilm (X100VI, X-E5, X-H2/H2S, X-M5, X-S20, X-T30 III, X-T5, X-T50) and Panasonic Lumix (S1 II, S1 IIE, L10). Not GoPro, which uses a proprietary protocol instead of standard UVC. No IP needed, just plug in and tap Connect. Live view and capture both come from the video feed rather than the shutter, so there is no hot-shoe flash sync and photo resolution is capped at the stream resolution, not the sensor's full still resolution."
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

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

/// Guest-facing camera brand choice on the connect screen. Only Canon has
/// been verified on hardware. Nikon/Fujifilm/generic-PTP support exists in
/// CameraKit but is deliberately not offered here right now — pruned down
/// to just the two brands actually in use/under test.
public enum CameraBrand: String, CaseIterable, Sendable, Identifiable {
    case canonEOS
    case sony
    case usbWebcam

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .canonEOS: "Canon EOS"
        case .sony: "Sony (beta)"
        case .usbWebcam: "USB Webcam (beta)"
        }
    }

    public var connectionHint: String {
        switch self {
        case .canonEOS:
            "Camera in Remote control (EOS Utility) Wi-Fi mode."
        case .sony:
            "Camera in Control with Smartphone / Smart Remote mode, iPad joined to the camera's Wi-Fi. Uses Sony's Camera Remote API (older α and RX bodies only — newer bodies dropped this in favor of Creators' App). Untested on hardware."
        case .usbWebcam:
            "Camera in USB Streaming/webcam mode, wired to the iPad over USB-C (e.g. Sony a7 IV+ with firmware 5.0+: Menu → Setup → USB → USB Connection Mode → USB Streaming). No IP needed — just plug in and tap Connect. Live view AND capture both come from the video feed, not the shutter — no hot-shoe flash sync, and photo resolution is capped at the stream's resolution, not the sensor's full still resolution. Untested on hardware."
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

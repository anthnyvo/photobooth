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
/// been verified on hardware; the others are best-effort implementations
/// of each vendor's documented PTP dialect, flagged as beta in the UI.
public enum CameraBrand: String, CaseIterable, Sendable, Identifiable {
    case canonEOS
    case nikon
    case genericPTP

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .canonEOS: "Canon EOS"
        case .nikon: "Nikon (beta)"
        case .genericPTP: "Other PTP (beta)"
        }
    }

    public var connectionHint: String {
        switch self {
        case .canonEOS:
            "Camera in Remote control (EOS Utility) Wi-Fi mode."
        case .nikon:
            "Camera in Wi-Fi/tethering mode with PTP/IP enabled. Untested on hardware — expect rough edges."
        case .genericPTP:
            "Any PTP/IP camera. Capture only — live view isn't part of standard PTP, so the screen shows no feed."
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

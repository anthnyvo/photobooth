import Foundation

/// Picks the protocol actor to drive a body that just appeared on the cable.
///
/// Any camera speaking PTP enumerates over USB — `ICCTransport` is
/// brand-agnostic, it is only the vendor opcodes above it that differ. So the
/// booth can accept whatever gets plugged in rather than requiring the one
/// body the app was written against, as long as it is honest about what each
/// tier can actually do.
public enum TetheredCameraFactory {

    /// What a given body is expected to manage once connected. Surfaced so the
    /// connect screen can tell an operator up front, rather than letting them
    /// discover mid-event that there is no live view.
    public enum Capability: Sendable {
        /// Live view and full-res capture. Hardware-proven.
        case full
        /// Live view and capture implemented, never run on real hardware.
        case unverified
        /// Capture only. Standard PTP has no live view at all, so the booth
        /// runs feed-less: strips, print and share still work, but anything
        /// built on the video feed (AR props, Boomerang, GIF, timelapse,
        /// smile shutter) has nothing to read.
        case captureOnly

        public var operatorNote: String? {
            switch self {
            case .full: nil
            case .unverified: "This body has never been tested on real hardware. Check a shot before guests arrive."
            case .captureOnly: "Photos will work. Live preview, AR props and Boomerang will not — this body has no preview over USB."
            }
        }
    }

    public struct Match: Sendable {
        public let camera: any TetheredCamera
        public let capability: Capability
        public let describedAs: String
    }

    /// Match on the name ImageCaptureCore reports, e.g. "Canon EOS R".
    ///
    /// Name matching rather than USB vendor IDs because that is what the iOS
    /// side actually hands us; `ICCameraDevice` exposes no vendor ID on this
    /// platform. It is coarse, but the fallback is a working capture path
    /// rather than a failure, so a miss costs live view rather than the event.
    public static func make(deviceName: String?, transport: any PTPTransport) -> Match {
        let name = (deviceName ?? "").lowercased()

        if name.contains("canon") || name.contains("eos") {
            return Match(camera: EOSCamera(transport: transport),
                         capability: .full,
                         describedAs: deviceName ?? "Canon")
        }

        if name.contains("nikon") {
            return Match(camera: NikonCamera(transport: transport),
                         capability: .unverified,
                         describedAs: deviceName ?? "Nikon")
        }

        // Everything else, Sony included. Sony bodies do speak PTP over USB
        // and will capture through this path, but their live view is a vendor
        // extension this app has not implemented — SonyCamera is the legacy
        // HTTP/Wi-Fi client and cannot be driven over a cable.
        return Match(camera: GenericPTPCamera(transport: transport),
                     capability: .captureOnly,
                     describedAs: deviceName ?? "camera")
    }
}

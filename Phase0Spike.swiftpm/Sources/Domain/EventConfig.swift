import Foundation

/// Everything that varies per client/event. Nothing about branding should be
/// hardcoded in the UI — every visual decision reads from here.
public struct EventConfig: Codable, Sendable, Equatable {
    public enum BrandingMode: String, Codable, Sendable {
        case custom, standard
    }

    public struct Colors: Codable, Sendable, Equatable {
        public var primaryHex: String
        public var backgroundHex: String

        public init(primaryHex: String = "#2563EB", backgroundHex: String = "#0B0F19") {
            self.primaryHex = primaryHex
            self.backgroundHex = backgroundHex
        }
    }

    public struct ShareOptions: Codable, Sendable, Equatable {
        public var airdrop: Bool
        public var qrGallery: Bool
        public var sms: Bool
        public var email: Bool

        public init(airdrop: Bool = true, qrGallery: Bool = true, sms: Bool = false, email: Bool = false) {
            self.airdrop = airdrop
            self.qrGallery = qrGallery
            self.sms = sms
            self.email = email
        }
    }

    public struct PrintOptions: Codable, Sendable, Equatable {
        public var enabled: Bool
        /// nil = unlimited
        public var limitPerGuest: Int?

        public init(enabled: Bool = true, limitPerGuest: Int? = nil) {
            self.enabled = enabled
            self.limitPerGuest = limitPerGuest
        }
    }

    public var eventId: String
    public var displayName: String
    public var branding: BrandingMode
    public var colors: Colors
    /// Relative filename inside the event's assets/ folder; nil for standard branding.
    public var logoAssetName: String?
    public var countdownSeconds: Int
    public var share: ShareOptions
    public var print: PrintOptions
    public var createdAt: Date

    public init(
        eventId: String,
        displayName: String,
        branding: BrandingMode = .standard,
        colors: Colors = Colors(),
        logoAssetName: String? = nil,
        countdownSeconds: Int = 5,
        share: ShareOptions = ShareOptions(),
        print: PrintOptions = PrintOptions(),
        createdAt: Date = Date()
    ) {
        self.eventId = eventId
        self.displayName = displayName
        self.branding = branding
        self.colors = colors
        self.logoAssetName = logoAssetName
        self.countdownSeconds = countdownSeconds
        self.share = share
        self.print = print
        self.createdAt = createdAt
    }

    /// Clean default used when a client didn't want/provide branding, and as
    /// the fallback if no event has been configured yet at all.
    public static func standardDefault(eventId: String = "standard") -> EventConfig {
        EventConfig(eventId: eventId, displayName: "Photobooth", branding: .standard)
    }
}

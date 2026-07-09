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

        public init(primaryHex: String = "#DBF24F", backgroundHex: String = "#0B0F19") {
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

    /// A frame/logo composited onto the actual saved photo (not just shown in
    /// the UI) — burned into the file so it's there in every shared/printed
    /// copy. Filename lives in the event's assets/ folder, same as the logo.
    public struct OverlayOptions: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var assetName: String?

        public init(enabled: Bool = false, assetName: String? = nil) {
            self.enabled = enabled
            self.assetName = assetName
        }

        public static let `default` = OverlayOptions()
    }

    /// Multiple shots composited into one photo instead of a single shot.
    /// shotCount/layout are only meaningful while enabled.
    public struct StripOptions: Codable, Sendable, Equatable {
        public enum Layout: String, Codable, Sendable, CaseIterable {
            /// Classic photobooth strip — shots stacked top to bottom.
            case vertical
            /// Shots side by side — good for a 2-shot "duo" pair or a wide
            /// group shot.
            case horizontal
            /// Shots arranged in a roughly square grid (ceil(sqrt(n)) columns).
            case grid
        }

        public var enabled: Bool
        public var shotCount: Int
        public var layout: Layout

        public init(enabled: Bool = false, shotCount: Int = 3, layout: Layout = .vertical) {
            self.enabled = enabled
            self.shotCount = shotCount
            self.layout = layout
        }

        public static let `default` = StripOptions()

        // `layout` decodes leniently — existing config.json files already
        // have a "strip" object (from before layout existed) with just
        // enabled/shotCount, and a synthesized Decodable would throw trying
        // to decode that object rather than skip it, unlike EventConfig's
        // outer decodeIfPresent which only guards against the whole key
        // being absent.
        private enum CodingKeys: String, CodingKey {
            case enabled, shotCount, layout
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            shotCount = try container.decode(Int.self, forKey: .shotCount)
            layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .vertical
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
    public var overlay: OverlayOptions
    public var strip: StripOptions
    /// Crops the final photo (single or strip) to a centered square before
    /// the Polaroid frame — independent of strip layout, so it applies to
    /// either a single shot or a composited strip.
    public var squareCrop: Bool
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
        overlay: OverlayOptions = OverlayOptions(),
        strip: StripOptions = StripOptions(),
        squareCrop: Bool = false,
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
        self.overlay = overlay
        self.strip = strip
        self.squareCrop = squareCrop
        self.createdAt = createdAt
    }

    /// Clean default used when a client didn't want/provide branding, and as
    /// the fallback if no event has been configured yet at all.
    public static func standardDefault(eventId: String = "standard") -> EventConfig {
        EventConfig(eventId: eventId, displayName: "Photobooth", branding: .standard)
    }

    // MARK: - Codable

    /// `overlay`/`strip` are decoded leniently (missing key -> disabled
    /// default) so config.json files written before these fields existed
    /// still load instead of crashing the booth on launch.
    private enum CodingKeys: String, CodingKey {
        case eventId, displayName, branding, colors, logoAssetName, countdownSeconds
        case share, print, overlay, strip, squareCrop, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decode(String.self, forKey: .eventId)
        displayName = try container.decode(String.self, forKey: .displayName)
        branding = try container.decode(BrandingMode.self, forKey: .branding)
        colors = try container.decode(Colors.self, forKey: .colors)
        logoAssetName = try container.decodeIfPresent(String.self, forKey: .logoAssetName)
        countdownSeconds = try container.decode(Int.self, forKey: .countdownSeconds)
        share = try container.decode(ShareOptions.self, forKey: .share)
        print = try container.decode(PrintOptions.self, forKey: .print)
        overlay = try container.decodeIfPresent(OverlayOptions.self, forKey: .overlay) ?? .default
        strip = try container.decodeIfPresent(StripOptions.self, forKey: .strip) ?? .default
        squareCrop = try container.decodeIfPresent(Bool.self, forKey: .squareCrop) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(branding, forKey: .branding)
        try container.encode(colors, forKey: .colors)
        try container.encodeIfPresent(logoAssetName, forKey: .logoAssetName)
        try container.encode(countdownSeconds, forKey: .countdownSeconds)
        try container.encode(share, forKey: .share)
        try container.encode(print, forKey: .print)
        try container.encode(overlay, forKey: .overlay)
        try container.encode(strip, forKey: .strip)
        try container.encode(squareCrop, forKey: .squareCrop)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

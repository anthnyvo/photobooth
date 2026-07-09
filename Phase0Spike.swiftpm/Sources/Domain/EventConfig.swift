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
    /// shotCounts/layout are only meaningful while enabled. Guests pick
    /// among the offered counts at the attract screen — this isn't one
    /// fixed number, so a 3-shot and a 4-shot strip can both be offered
    /// side by side at the same event.
    public struct StripOptions: Codable, Sendable, Equatable {
        public enum Layout: String, Codable, Sendable, CaseIterable, Comparable {
            /// Classic photobooth strip — shots stacked top to bottom.
            case vertical
            /// Shots side by side — good for a 2-shot "duo" pair or a wide
            /// group shot.
            case horizontal
            /// Shots arranged in a roughly square grid (ceil(sqrt(n)) columns).
            case grid

            var displayName: String {
                switch self {
                case .vertical: "Vertical"
                case .horizontal: "Horizontal"
                case .grid: "Grid"
                }
            }

            public static func < (lhs: Layout, rhs: Layout) -> Bool {
                (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
            }
        }

        public var enabled: Bool
        /// The shot-count options offered at the attract screen — e.g. [3, 4]
        /// shows both a "3-Shot" and a "4-Shot" button. Always non-empty
        /// while enabled; falls back to [3] if a config somehow ends up empty.
        public var shotCounts: [Int]
        /// The layout options offered at the attract screen — e.g. all three
        /// offers a vertical, horizontal, and grid button for every shot
        /// count, same idea as shotCounts: guests pick, not one fixed layout.
        /// Always non-empty while enabled; falls back to [.vertical].
        public var layouts: [Layout]

        public init(enabled: Bool = false, shotCounts: [Int] = [3], layouts: [Layout] = [.vertical]) {
            self.enabled = enabled
            self.shotCounts = shotCounts
            self.layouts = layouts
        }

        public static let `default` = StripOptions()

        // Decodes leniently — existing config.json files predate `layouts`
        // (single "layout") and this multi-count `shotCounts` (single
        // "shotCount"), and a synthesized Decodable would throw trying to
        // decode those older shapes rather than skip them, unlike
        // EventConfig's outer decodeIfPresent which only guards against the
        // whole "strip" key being absent.
        private enum CodingKeys: String, CodingKey {
            case enabled, shotCount, shotCounts, layout, layouts
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            if let counts = try container.decodeIfPresent([Int].self, forKey: .shotCounts), !counts.isEmpty {
                shotCounts = counts
            } else if let legacyCount = try container.decodeIfPresent(Int.self, forKey: .shotCount) {
                shotCounts = [legacyCount]
            } else {
                shotCounts = [3]
            }
            if let decodedLayouts = try container.decodeIfPresent([Layout].self, forKey: .layouts), !decodedLayouts.isEmpty {
                layouts = decodedLayouts
            } else if let legacyLayout = try container.decodeIfPresent(Layout.self, forKey: .layout) {
                layouts = [legacyLayout]
            } else {
                layouts = [.vertical]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(shotCounts, forKey: .shotCounts)
            try container.encode(layouts, forKey: .layouts)
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
    /// Shows the guest-facing filter chips (Retro, B&W, ...) on the attract
    /// screen. The filter itself is per-guest, not per-event — this only
    /// controls whether the choice is offered at all.
    public var filtersEnabled: Bool
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
        filtersEnabled: Bool = true,
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
        self.filtersEnabled = filtersEnabled
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
        case share, print, overlay, strip, squareCrop, filtersEnabled, createdAt
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
        filtersEnabled = try container.decodeIfPresent(Bool.self, forKey: .filtersEnabled) ?? true
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
        try container.encode(filtersEnabled, forKey: .filtersEnabled)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

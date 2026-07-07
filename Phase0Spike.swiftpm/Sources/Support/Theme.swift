import SwiftUI

/// Reads colors from the active EventConfig — no hardcoded branding colors
/// anywhere in the guest-facing UI.
public struct Theme {
    public let primary: Color
    public let background: Color

    public init(_ config: EventConfig) {
        primary = Color(hex: config.colors.primaryHex) ?? .blue
        background = Color(hex: config.colors.backgroundHex) ?? .black
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

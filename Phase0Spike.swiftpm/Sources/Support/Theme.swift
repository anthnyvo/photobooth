import SwiftUI

/// Reads colors from the active EventConfig — no hardcoded branding colors
/// anywhere in the guest-facing UI. The event's primary color is the single
/// accent; everything else (Chassis below) is the app's fixed dark shell and
/// is deliberately NOT event-configurable.
public struct Theme {
    public let primary: Color
    public let background: Color

    public init(_ config: EventConfig) {
        primary = Color(hex: config.colors.primaryHex) ?? .blue
        background = Color(hex: config.colors.backgroundHex) ?? Chassis.base
    }
}

/// The structural palette: near-black surfaces, dark panel cards with
/// hairline strokes, circular dial-style controls, muted uppercase labels.
/// Branding only ever supplies the accent color — keeping the chassis fixed
/// is what makes every event's booth feel like the same piece of hardware.
public enum Chassis {
    public static let base = Color(red: 0.043, green: 0.043, blue: 0.047)
    public static let panel = Color(red: 0.094, green: 0.094, blue: 0.102)
    public static let control = Color(red: 0.125, green: 0.125, blue: 0.137)
    public static let controlHighlight = Color(red: 0.165, green: 0.165, blue: 0.18)
    public static let hairline = Color.white.opacity(0.09)
    public static let textPrimary = Color.white.opacity(0.92)
    public static let textSecondary = Color.white.opacity(0.45)
}

extension View {
    /// Dark rounded panel card with a hairline stroke.
    func chassisPanel(cornerRadius: CGFloat = 20) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Chassis.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Chassis.hairline, lineWidth: 1)
        )
    }
}

/// Small uppercase tracked label — the only text style used for control
/// captions and section headings in the guest UI.
struct ChassisLabel: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(Chassis.textSecondary)
    }
}

/// Circular dial-style control: a dark knob with a hairline ring and an
/// icon, uppercase caption beneath. `accent` tints the icon (and adds a
/// faint accent ring) for the primary action; nil keeps it neutral.
struct DialButton: View {
    let label: String
    let systemImage: String
    var accent: Color? = nil
    var diameter: CGFloat = 88
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Chassis.controlHighlight, Chassis.control],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    Circle()
                        .strokeBorder(accent?.opacity(0.55) ?? Chassis.hairline, lineWidth: 1)
                    Circle()
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                        .padding(7)
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.3, weight: .medium))
                        .foregroundStyle(accent ?? Chassis.textPrimary)
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)

                ChassisLabel(text: label, size: 11)
            }
        }
        .buttonStyle(.plain)
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

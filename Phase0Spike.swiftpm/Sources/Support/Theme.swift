import SwiftUI

/// Reads colors from the active EventConfig — no hardcoded branding colors
/// anywhere in the guest-facing UI. The event's primary color is the single
/// accent; everything else (Chassis below) is the app's fixed shell and is
/// deliberately NOT event-configurable.
public struct Theme {
    public let primary: Color
    public let background: Color

    public init(_ config: EventConfig) {
        primary = Color(hex: config.colors.primaryHex) ?? Chassis.accent
        background = Color(hex: config.colors.backgroundHex) ?? Chassis.base
    }
}

/// The structural palette: a soft purple/orange gradient backdrop with dark
/// glassy cards floating on top, modern iOS capsule buttons, and a bright
/// lime accent as the default. Branding only ever supplies the accent color —
/// keeping the chassis fixed is what makes every event's booth feel like the
/// same piece of hardware.
public enum Chassis {
    /// Default accent (bright lime) — used when the event doesn't override it.
    public static let accent = Color(red: 0.86, green: 0.95, blue: 0.31)
    /// Solid dark base for screens where the live view IS the background
    /// (capture, ready-to-shoot) and for sheets.
    public static let base = Color(red: 0.055, green: 0.05, blue: 0.07)
    /// Glassy card fill — always used with some translucency over the
    /// gradient so the backdrop glows through.
    public static let card = Color(red: 0.075, green: 0.07, blue: 0.09)
    public static let control = Color(red: 0.16, green: 0.15, blue: 0.18)
    public static let hairline = Color.white.opacity(0.10)
    public static let textPrimary = Color.white.opacity(0.94)
    public static let textSecondary = Color.white.opacity(0.55)
}

/// The signature backdrop: dusty purple gradient with a warm orange glow
/// up top and a cooler violet bloom below — matches the soft, blurred
/// gradient look, with dark cards floating on top.
struct ChassisBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.64, green: 0.58, blue: 0.71),
                    Color(red: 0.47, green: 0.42, blue: 0.55),
                    Color(red: 0.36, green: 0.32, blue: 0.44)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.87, green: 0.55, blue: 0.30).opacity(0.55))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -150, y: -280)
            Circle()
                .fill(Color(red: 0.52, green: 0.42, blue: 0.72).opacity(0.5))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: 170, y: 320)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Dark glassy card with a hairline stroke and big modern corner radius,
    /// slightly translucent so the gradient backdrop glows through.
    func chassisPanel(cornerRadius: CGFloat = 28) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Chassis.card.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Chassis.hairline, lineWidth: 1)
        )
    }
}

/// Small uppercase tracked label — used for control captions and section
/// headings in the guest UI.
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

/// Modern iOS capsule button. `prominent` = solid white pill with black
/// text (the primary CTA look); otherwise a dark glassy pill.
struct PillButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Chassis.textPrimary)
                .padding(.vertical, 16)
                .padding(.horizontal, 44)
                .background(
                    Capsule().fill(prominent ? Color.white : Chassis.card.opacity(0.86))
                )
                .overlay(
                    Capsule().strokeBorder(prominent ? Color.clear : Chassis.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }
}

/// Circular icon control: dark glassy disc with an icon, uppercase caption
/// beneath. `accent` fills the disc with the accent color and flips the icon
/// to black — the bright circular action button look.
struct DialButton: View {
    let label: String
    let systemImage: String
    var accent: Color? = nil
    var diameter: CGFloat = 84
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accent ?? Chassis.card.opacity(0.86))
                    if accent == nil {
                        Circle()
                            .strokeBorder(Chassis.hairline, lineWidth: 1)
                    }
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.3, weight: .medium))
                        .foregroundStyle(accent != nil ? Color.black : Chassis.textPrimary)
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

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

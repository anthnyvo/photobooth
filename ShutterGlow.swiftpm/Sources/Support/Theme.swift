import SwiftUI
import BoothStorage

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

/// The signature backdrop: near-black base (matching the marketing site)
/// with a faint dusty-purple wash and dim warm/cool glow blooms — dark
/// enough that glass cards and white type carry the contrast, the blooms
/// just keep it from reading as flat black.
struct ChassisBackground: View {
    /// Ambient drift — the blooms wander slowly forever, so no screen in
    /// the app is ever fully static. Core Animation drives it (repeating
    /// spring offsets), no per-frame CPU.
    @State private var drift = false

    var body: some View {
        ZStack {
            Chassis.base
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.13, blue: 0.20),
                    Color(red: 0.09, green: 0.08, blue: 0.12),
                    Chassis.base
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .opacity(0.9)
            Circle()
                .fill(Color(red: 0.87, green: 0.55, blue: 0.30).opacity(drift ? 0.26 : 0.18))
                .frame(width: 420, height: 420)
                .blur(radius: 100)
                .offset(x: drift ? -110 : -170, y: drift ? -250 : -300)
                .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true), value: drift)
            Circle()
                .fill(Color(red: 0.52, green: 0.42, blue: 0.72).opacity(drift ? 0.18 : 0.26))
                .frame(width: 380, height: 380)
                .blur(radius: 110)
                .offset(x: drift ? 200 : 140, y: drift ? 290 : 340)
                .animation(.easeInOut(duration: 13).repeatForever(autoreverses: true), value: drift)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }
}

extension View {
    /// Real frosted-glass card: `.ultraThinMaterial` blur (not a flat
    /// semi-opaque color) so the backdrop shows through blurred, plus a
    /// top-lit gradient hairline — brighter along the top edge, fading down
    /// — which is what makes glass read as a lit physical surface instead
    /// of an outlined rectangle.
    func chassisPanel(cornerRadius: CGFloat = 28) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    /// Standard staggered entrance: rise + fade with a weighty spring,
    /// offset by `delay` so sibling elements cascade instead of appearing
    /// as one block. Drive with a Bool the container flips in onAppear.
    func entrance(_ shown: Bool, delay: Double = 0) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .animation(.spring(duration: 0.65, bounce: 0.18).delay(delay), value: shown)
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

/// Press-responsive button style — quick scale-down + slight dim on touch,
/// the tactile micro-interaction that separates modern iOS controls from
/// static tap targets. Used by every custom button in the app.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
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
                    Capsule().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                )
                .overlay(
                    Capsule().strokeBorder(prominent ? Color.clear : Chassis.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Circular icon control: dark glassy disc with an icon, uppercase caption
/// beneath. `accent` fills the disc with the accent color and flips the icon
/// to black — the bright circular action button look. `isSelected` renders
/// the same inverted look in white, for pick-then-confirm flows where
/// tapping marks a choice rather than firing an action.
struct DialButton: View {
    let label: String
    let systemImage: String
    var accent: Color? = nil
    var isSelected: Bool = false
    var diameter: CGFloat = 84
    let action: () -> Void

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white) }
        return accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(.ultraThinMaterial)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(fill)
                    if accent == nil && !isSelected {
                        Circle()
                            .strokeBorder(Chassis.hairline, lineWidth: 1)
                    }
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.3, weight: .medium))
                        .foregroundStyle(accent != nil || isSelected ? Color.black : Chassis.textPrimary)
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

                ChassisLabel(text: label, size: 11)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

/// Small glassy circular back button — chevron on a dark glass disc.
/// Callers place it top-leading with their own safe-area padding.
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Chassis.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Chassis.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Back")
    }
}

/// Low-key glassy text button — for secondary actions (Cancel, links) that
/// don't warrant a full-weight PillButton but still shouldn't be bare
/// system-styled text.
struct GhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Chassis.textSecondary)
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
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

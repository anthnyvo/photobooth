import SwiftUI

/// Miniature "what you'll get" previews for the attract screen's mode
/// picker — a 3-shot vertical strip option shows an actual tiny 3-frame
/// polaroid strip, not an abstract icon, so guests can see the output
/// before picking. All vector-drawn (no bundled art): white print stock,
/// dusty-gradient photo placeholders.
struct ModePreviewCard: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let art: () -> AnyView

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    // Preview art is vector-drawn at its own fixed small
                    // constants (see PhotoSwatch/StripPreview/etc.) — scale
                    // it up to actually fill the enlarged card instead of
                    // floating small in extra whitespace. Clipped so the
                    // scaled content can't spill past the rounded corners.
                    art()
                        .scaleEffect(1.35)
                }
                .frame(width: 132, height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(.ultraThinMaterial))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Chassis.hairline, lineWidth: isSelected ? 2 : 1)
                )
                .shadow(color: .black.opacity(isSelected ? 0.45 : 0.25), radius: 10, y: 4)
                // selected card lifts and glows faintly white — the pick
                // should look lit, not just outlined
                .shadow(color: .white.opacity(isSelected ? 0.18 : 0), radius: 16)
                .scaleEffect(isSelected ? 1.04 : 0.94)
                .animation(.spring(duration: 0.35, bounce: 0.3), value: isSelected)

                ChassisLabel(text: title, size: 13)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

/// One tiny "photo" — the dusty purple gradient with a warm bloom, standing
/// in for the picture inside every preview frame.
struct PhotoSwatch: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.64, green: 0.58, blue: 0.71),
                        Color(red: 0.47, green: 0.42, blue: 0.55)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color(red: 0.87, green: 0.55, blue: 0.30).opacity(0.6))
                    .frame(width: 14, height: 14)
                    .blur(radius: 5)
                    .offset(x: -2, y: -2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
    }
}

/// Single photo: classic polaroid — one frame on white stock with the
/// signature chin.
struct SinglePolaroidPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            PhotoSwatch()
                .aspectRatio(4 / 3, contentMode: .fit)
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(width: 62, height: 68)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .rotationEffect(.degrees(-3))
    }
}

/// N-shot strip in any layout — vertical stack, horizontal row, or grid —
/// on white print stock, mirroring PhotoCompositor's real output shapes.
struct StripPreview: View {
    let count: Int
    let layout: EventConfig.StripOptions.Layout

    var body: some View {
        Group {
            switch layout {
            case .vertical:
                VStack(spacing: 2.5) {
                    ForEach(0..<count, id: \.self) { _ in
                        PhotoSwatch().aspectRatio(4 / 3, contentMode: .fit)
                    }
                }
                .padding(4)
                .frame(width: 34)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white))
            case .horizontal:
                HStack(spacing: 2.5) {
                    ForEach(0..<count, id: \.self) { _ in
                        PhotoSwatch().frame(width: 15, height: 20)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white))
            case .grid:
                let columns = Int(ceil(sqrt(Double(count))))
                let rows = Int(ceil(Double(count) / Double(columns)))
                VStack(spacing: 2.5) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 2.5) {
                            ForEach(0..<columns, id: \.self) { column in
                                if row * columns + column < count {
                                    PhotoSwatch().frame(width: 22, height: 16)
                                } else {
                                    Color.clear.frame(width: 22, height: 16)
                                }
                            }
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .rotationEffect(.degrees(-2))
    }
}

/// Filter preview: the same polaroid, tinted to approximate each look —
/// enough visual difference that guests compare looks at a glance without
/// running Core Image per card.
struct FilterPreview: View {
    let filter: PhotoFilter

    var body: some View {
        VStack(spacing: 0) {
            PhotoSwatch()
                .aspectRatio(4 / 3, contentMode: .fit)
                // same values the live view preview uses (LiveFilterEffect),
                // so the card and the full-screen look always agree
                .saturation(filter.previewSaturation)
                .contrast(filter.previewContrast)
                .overlay(filter.previewTint)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(width: 62, height: 68)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .rotationEffect(.degrees(-3))
    }
}

/// Prop preview: a simple face with the prop drawn on it — same shapes the
/// real renderer burns into the photo, miniaturized.
struct PropPreview: View {
    let prop: PhotoProp

    var body: some View {
        ZStack {
            // face
            Circle()
                .fill(Color(red: 0.94, green: 0.80, blue: 0.64))
                .frame(width: 52, height: 52)
            // eyes
            HStack(spacing: 14) {
                Circle().fill(Color.black.opacity(0.75)).frame(width: 5, height: 5)
                Circle().fill(Color.black.opacity(0.75)).frame(width: 5, height: 5)
            }
            .offset(y: -4)
            // smile
            SmileArc()
                .stroke(Color.black.opacity(0.6), lineWidth: 2)
                .frame(width: 18, height: 9)
                .offset(y: 11)

            propShapes
        }
        .frame(width: 74, height: 80)
    }

    @ViewBuilder
    private var propShapes: some View {
        switch prop {
        case .none:
            EmptyView()
        case .sunglasses:
            HStack(spacing: 3) {
                Circle().fill(Color.black.opacity(0.9)).frame(width: 16, height: 16)
                Rectangle().fill(Color.black.opacity(0.9)).frame(width: 4, height: 2.5)
                Circle().fill(Color.black.opacity(0.9)).frame(width: 16, height: 16)
            }
            .offset(y: -4)
        case .mustache:
            Capsule()
                .fill(Color(red: 0.16, green: 0.10, blue: 0.06))
                .frame(width: 22, height: 6)
                .offset(y: 6)
        case .dogEars:
            HStack(spacing: 24) {
                Ellipse().fill(Color(red: 0.55, green: 0.36, blue: 0.20)).frame(width: 14, height: 20)
                Ellipse().fill(Color(red: 0.55, green: 0.36, blue: 0.20)).frame(width: 14, height: 20)
            }
            .offset(y: -25)
            Ellipse().fill(Color.black.opacity(0.9)).frame(width: 11, height: 8).offset(y: 4)
        case .crown:
            CrownShape()
                .fill(Color(red: 0.96, green: 0.77, blue: 0.26))
                .frame(width: 36, height: 18)
                .offset(y: -33)
        case .hearts:
            ForEach(0..<3, id: \.self) { index in
                Text("♥")
                    .font(.system(size: 13 + CGFloat(index) * 2))
                    .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.38))
                    .offset(
                        x: [-28, 0, 28][index],
                        y: [-18, -32, -18][index]
                    )
            }
        case .flowerCrown:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill([
                            Color(red: 0.96, green: 0.55, blue: 0.68),
                            Color(red: 0.99, green: 0.85, blue: 0.35),
                            Color(red: 0.85, green: 0.42, blue: 0.85),
                        ][i])
                        .frame(width: 11, height: 11)
                }
            }
            .offset(y: -27)
        case .bunnyEars:
            HStack(spacing: 12) {
                bunnyEar
                bunnyEar
            }
            .offset(y: -35)
        case .catWhiskers:
            ZStack {
                HStack(spacing: 20) {
                    Triangle().fill(Color(red: 0.42, green: 0.40, blue: 0.44)).frame(width: 15, height: 14)
                    Triangle().fill(Color(red: 0.42, green: 0.40, blue: 0.44)).frame(width: 15, height: 14)
                }
                .offset(y: -26)
                Ellipse()
                    .fill(Color(red: 0.93, green: 0.62, blue: 0.68))
                    .frame(width: 7, height: 5)
                    .offset(y: 5)
            }
        case .devilHorns:
            HStack(spacing: 24) {
                Triangle().fill(Color(red: 0.82, green: 0.14, blue: 0.18)).frame(width: 9, height: 13)
                Triangle().fill(Color(red: 0.82, green: 0.14, blue: 0.18)).frame(width: 9, height: 13)
            }
            .offset(y: -30)
        case .rainbow:
            RainbowArc()
                .stroke(
                    AngularGradient(
                        colors: [.red, .orange, .yellow, .green, .blue, .purple],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 32, height: 16)
                .offset(y: 15)
        }
    }

    private var bunnyEar: some View {
        ZStack {
            Capsule().fill(Color.white).frame(width: 9, height: 26)
            Capsule().fill(Color(red: 0.94, green: 0.62, blue: 0.68)).frame(width: 4, height: 18)
        }
    }
}

private struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY),
            radius: rect.width / 2,
            startAngle: .degrees(30), endAngle: .degrees(150),
            clockwise: false
        )
        return path
    }
}

private struct CrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for spike in 0..<3 {
            let left = rect.minX + rect.width * CGFloat(spike) / 3
            path.addLine(to: CGPoint(x: left, y: rect.maxY * 0.5))
            path.addLine(to: CGPoint(x: left + rect.width / 6, y: rect.minY))
            path.addLine(to: CGPoint(x: left + rect.width / 3, y: rect.maxY * 0.5))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct RainbowArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY),
            radius: rect.width / 2,
            startAngle: .degrees(30), endAngle: .degrees(150),
            clockwise: false
        )
        return path
    }
}

/// GIF/Boomerang: a photo frame with motion cues — offset ghost frames
/// behind, and a badge naming the format.
struct AnimatedPreview: View {
    let style: AnimatedStyle

    var body: some View {
        ZStack {
            // ghost frames trailing behind suggest motion
            ForEach(0..<2, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.35 - Double(index) * 0.15))
                    .frame(width: 56, height: 46)
                    .rotationEffect(.degrees(Double(index + 1) * 7))
                    .offset(x: CGFloat(index + 1) * 5, y: CGFloat(index + 1) * -3)
            }
            VStack(spacing: 0) {
                PhotoSwatch().aspectRatio(4 / 3, contentMode: .fit)
            }
            .padding(4)
            .frame(width: 56)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            Text(style == .gif ? "GIF" : "⇄")
                .font(.system(size: style == .gif ? 10 : 14, weight: .heavy))
                .foregroundStyle(Color.black)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Capsule().fill(Chassis.accent))
                .offset(y: 26)
        }
    }
}

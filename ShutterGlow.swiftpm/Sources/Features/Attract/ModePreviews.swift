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
            VStack(spacing: 10) {
                ZStack {
                    art()
                }
                .frame(width: 96, height: 104)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(.ultraThinMaterial))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Chassis.hairline, lineWidth: isSelected ? 2 : 1)
                )
                .shadow(color: .black.opacity(isSelected ? 0.45 : 0.25), radius: 10, y: 4)
                .scaleEffect(isSelected ? 1.0 : 0.94)
                .animation(.easeOut(duration: 0.15), value: isSelected)

                ChassisLabel(text: title, size: 10)
            }
        }
        .buttonStyle(.plain)
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

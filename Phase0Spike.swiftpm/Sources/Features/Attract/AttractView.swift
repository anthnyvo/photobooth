import SwiftUI

/// Idle/attract screen — loops live view as a backdrop with a shutter-ring
/// "tap to start" control. Branding-driven: logo and accent color come from
/// EventConfig; the dark chassis styling is fixed (see Theme.swift).
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme

    var body: some View {
        ZStack {
            Chassis.base.ignoresSafeArea()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Chassis.base.opacity(0.55).ignoresSafeArea())
            }

            VStack(spacing: 24) {
                Spacer()
                if let logoName = model.config.logoAssetName {
                    let url = EventStorage.shared.assetURL(eventId: model.config.eventId, filename: logoName)
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 140)
                    }
                }
                Text(model.config.displayName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Chassis.textPrimary)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                Spacer()

                // Shutter-ring start control: outer hairline ring, accent
                // inner disc — reads as a camera control, not a web button.
                Button(action: model.tapToStart) {
                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Chassis.panel.opacity(0.85))
                            Circle()
                                .strokeBorder(Chassis.hairline, lineWidth: 1)
                            Circle()
                                .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                                .padding(10)
                            Circle()
                                .fill(theme.primary)
                                .padding(18)
                        }
                        .frame(width: 108, height: 108)
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)

                        ChassisLabel(text: "Tap to Start")
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 56)
            }

            if let error = model.lastError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Chassis.textPrimary)
                        .padding(10)
                        .background(.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tapToStart() }
    }
}

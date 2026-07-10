import SwiftUI

/// Live view with the countdown overlay, shown from the moment a guest taps
/// Start through the shutter firing. Countdown must be readable from a few
/// feet back (group shots) — large number, high contrast.
struct CaptureView: View {
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
                    .liveFilterEffect(model.selectedFilter)
                if let propOverlay = model.livePropOverlay {
                    Image(uiImage: propOverlay)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }

            switch model.step {
            case .countdown(let remaining):
                // No background ring — it obstructed the live view guests
                // are trying to pose against. Just the numeral, high
                // contrast, still readable from a few feet back.
                Text("\(remaining)")
                    .font(.system(size: 190, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 14)
                    .id(remaining)
                    .transition(.scale.combined(with: .opacity))
            case .capturing:
                Color.white.ignoresSafeArea()
                    .opacity(0.9)
                    .transition(.opacity)
            case .recording:
                // Boomerang/GIF recording — live view stays fully visible
                // (no flash) so guests can see themselves move; just a
                // pulsing REC badge.
                VStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 12, height: 12)
                        ChassisLabel(text: "Recording", size: 13)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .chassisPanel(cornerRadius: 20)
                    .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
            default:
                EmptyView()
            }

            if let progress = model.stripProgress {
                VStack {
                    ChassisLabel(text: "Shot \(progress.shot) of \(progress.total)", size: 13)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .chassisPanel(cornerRadius: 20)
                        .padding(.top, 24)
                    Spacer()
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.step)
        .task { await model.runLivePropOverlayLoop() }
    }
}

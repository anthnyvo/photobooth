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
    }
}

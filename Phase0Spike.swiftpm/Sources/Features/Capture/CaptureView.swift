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
                // Number sits inside a faint dial ring — matches the chassis
                // styling without hurting the from-a-few-feet readability the
                // giant numeral exists for.
                ZStack {
                    Circle()
                        .fill(Chassis.base.opacity(0.35))
                    Circle()
                        .strokeBorder(.white.opacity(0.35), lineWidth: 2)
                    Text("\(remaining)")
                        .font(.system(size: 190, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 12)
                        .id(remaining)
                }
                .frame(width: 300, height: 300)
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

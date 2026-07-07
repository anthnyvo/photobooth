import SwiftUI

/// Live view with the countdown overlay, shown from the moment a guest taps
/// Start through the shutter firing. Countdown must be readable from a few
/// feet back (group shots) — large number, high contrast.
struct CaptureView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }

            switch model.step {
            case .countdown(let remaining):
                Text("\(remaining)")
                    .font(.system(size: 220, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .transition(.scale.combined(with: .opacity))
                    .id(remaining)
            case .capturing:
                Color.white.ignoresSafeArea()
                    .opacity(0.9)
                    .transition(.opacity)
            default:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.step)
    }
}

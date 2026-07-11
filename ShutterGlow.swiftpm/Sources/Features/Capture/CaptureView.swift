import SwiftUI

/// Live view with the countdown overlay, shown from the moment a guest taps
/// Start through the shutter firing. Countdown must be readable from a few
/// feet back (group shots) — large number, high contrast.
struct CaptureView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme

    private var isCapturing: Bool {
        model.step == .capturing
    }

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
                // are trying to pose against. Each digit lands with a
                // spring-scale + blur-out of the previous one, plus a
                // haptic tick per second.
                Text("\(remaining)")
                    .font(.system(size: 190, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 14)
                    .id(remaining)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 1.5).combined(with: .opacity),
                            removal: .scale(scale: 0.7).combined(with: .opacity)
                        )
                    )
                    .sensoryFeedback(.impact(weight: .light), trigger: remaining)
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
                        RecordingDot()
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
        // heavy thunk when the shutter actually fires — the physical
        // moment of the whole experience
        .sensoryFeedback(.impact(weight: .heavy), trigger: isCapturing)
        .task { await model.runLivePropOverlayLoop() }
    }
}

/// REC indicator that actually pulses — a static red circle reads as a
/// stuck UI; breathing scale + glow reads as "live".
private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulsing ? 1.25 : 0.85)
            .shadow(color: .red.opacity(pulsing ? 0.8 : 0.2), radius: pulsing ? 8 : 2)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

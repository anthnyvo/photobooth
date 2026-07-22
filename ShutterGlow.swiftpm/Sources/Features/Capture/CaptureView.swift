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

            LiveViewBackdrop(feed: model.liveFeed, filter: model.selectedFilter)

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
                // A brief white pop that fades to reveal the frame, NOT a
                // solid white block held for the whole capture. Post-capture
                // compositing (green screen, polaroid, encode) runs off-main
                // while step stays .capturing, and sitting on opaque white for
                // those seconds read as the app hanging. The flash fades fast
                // and a "Developing" cue takes over only if processing runs
                // long, so the guest sees motion the whole time.
                ShutterFlash()
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

            // Hidden while the flash is up — a dark glass pill floating on
            // the white flash looked like a broken patch of screen.
            if let progress = model.stripProgress, !isCapturing {
                VStack {
                    ChassisLabel(text: "Shot \(progress.shot) of \(progress.total)", size: 13)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .chassisPanel(cornerRadius: 20)
                        .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.step)
        // heavy thunk when the shutter actually fires — the physical
        // moment of the whole experience
        .sensoryFeedback(.impact(weight: .heavy), trigger: isCapturing)
        .task { await model.runLivePropOverlayLoop() }
    }
}

/// The shutter flash: an instant white pop that fades out over a quarter
/// second to reveal the frame underneath, then — only if the capture is still
/// processing a beat later — a small "Developing" cue. This replaces holding
/// an opaque white screen for the entire post-capture compositing pass, which
/// looked like the app had frozen. A fast single shot flips to the review
/// screen before the "Developing" cue ever appears.
private struct ShutterFlash: View {
    @State private var flash = 1.0
    @State private var showDeveloping = false

    var body: some View {
        ZStack {
            Color.white.opacity(flash).ignoresSafeArea()

            if showDeveloping {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Chassis.textPrimary)
                        ChassisLabel(text: "Developing", size: 13)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .chassisPanel(cornerRadius: 20)
                    .padding(.bottom, 44)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { flash = 0 }
            Task {
                // 1s, deliberately longer than the ~800ms repose gap between
                // strip shots (which also sits in .capturing) so the cue never
                // flashes there — it only appears when real compositing runs
                // long on the final shot.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation(.easeIn(duration: 0.2)) { showDeveloping = true }
            }
        }
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

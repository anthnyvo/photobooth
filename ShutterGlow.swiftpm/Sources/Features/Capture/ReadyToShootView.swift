import SwiftUI

/// Shown after the guest picks how they want to shoot (or, when strip mode
/// is off, right after "Tap to Start") — live view stays up so they can pose,
/// and the countdown only begins once they touch again. Keeps "pick a mode"
/// and "we're about to start" as two distinct moments instead of the
/// countdown firing the instant a guest taps Single/Strip on Attract.
struct ReadyToShootView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    @State private var faceCount = 0

    private var smileShutterOn: Bool { model.config.ai.smileShutter }

    var body: some View {
        ZStack {
            ChassisBackground()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .liveFilterEffect(model.selectedFilter)
                    .overlay(Chassis.base.opacity(0.35).ignoresSafeArea())
                if let propOverlay = model.livePropOverlay {
                    Image(uiImage: propOverlay)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }

            VStack {
                HStack {
                    BackButton { model.cancelReadyToShoot() }
                    Spacer()
                    if smileShutterOn {
                        HStack(spacing: 8) {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 14, weight: .semibold))
                            Text(faceCount == 1 ? "1 face" : "\(faceCount) faces")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Chassis.textPrimary)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }

            VStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                    Circle()
                        .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                        .padding(10)
                    Circle()
                        .fill(Chassis.textPrimary)
                        .padding(18)
                }
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .padding(.bottom, 18)

                ChassisLabel(text: smileShutterOn ? "Smile to Shoot — or touch" : "Touch to Shoot")
                Spacer()
            }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { model.confirmReadyToShoot() }
        .onAppear { model.scheduleAutoReturn(after: 15) }
        .task { await model.runLivePropOverlayLoop() }
        .task {
            // Smile-shutter poll — ~2 scans/sec on the live feed, cancelled
            // automatically when this view leaves (touch, back, timeout).
            // Short arming delay so a guest who was already grinning while
            // tapping a mode doesn't trigger the countdown instantly.
            guard smileShutterOn else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            while !Task.isCancelled {
                let reading = await model.analyzeLiveViewFaces()
                faceCount = reading.faceCount
                if reading.smiling {
                    model.confirmReadyToShoot()
                    return
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }
}

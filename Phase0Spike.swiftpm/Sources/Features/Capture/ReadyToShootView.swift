import SwiftUI

/// Shown after the guest picks how they want to shoot (or, when strip mode
/// is off, right after "Tap to Start") — live view stays up so they can pose,
/// and the countdown only begins once they touch again. Keeps "pick a mode"
/// and "we're about to start" as two distinct moments instead of the
/// countdown firing the instant a guest taps Single/Strip on Attract.
struct ReadyToShootView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme

    var body: some View {
        ZStack {
            ChassisBackground()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Chassis.base.opacity(0.35).ignoresSafeArea())
            }

            VStack {
                HStack {
                    BackButton { model.cancelReadyToShoot() }
                    Spacer()
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

                ChassisLabel(text: "Touch to Shoot")
                    .padding(.bottom, 56)
            }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { model.confirmReadyToShoot() }
        .onAppear { model.scheduleAutoReturn(after: 15) }
    }
}

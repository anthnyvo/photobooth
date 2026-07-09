import SwiftUI

/// Splash screen shown once at launch, before the event picker list —
/// branded landing moment (shutter-ring mark, app name) with a single
/// "Get Started" action into event selection.
struct HomeView: View {
    @ObservedObject var model: BoothViewModel

    var body: some View {
        ZStack {
            ChassisBackground()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                    Circle()
                        .strokeBorder(.white.opacity(0.8), lineWidth: 4)
                        .padding(14)
                    Circle()
                        .fill(Chassis.accent)
                        .padding(26)
                }
                .frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)

                VStack(spacing: 10) {
                    Text("Photobooth")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Chassis.textPrimary)
                    Text("Tethered to your camera. No cloud, no backend.")
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()

                PillButton(title: "Get Started") {
                    model.enterEventPicker()
                }
                .padding(.bottom, 56)
            }
        }
        .statusBarHidden()
    }
}

import SwiftUI

/// Retake-or-accept screen shown right after capture. The photo "develops"
/// in — starts washed out and slightly small like a fresh print, then
/// settles to full contrast with a weighty spring — before the actions
/// cascade up. A shot arriving should feel like a moment, not a repaint.
struct ReviewView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL
    @State private var developed = false

    var body: some View {
        ZStack {
            ChassisBackground()
            VStack(spacing: 32) {
                if let uiImage = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            // develop wash — white veil that lifts
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)
                                .opacity(developed ? 0 : 0.85)
                        )
                        .saturation(developed ? 1 : 0.3)
                        .overlay(alignment: .topTrailing) {
                            // GIFs preview as their first frame here (SwiftUI
                            // Image doesn't animate) — badge makes clear the
                            // real file moves.
                            if photoURL.pathExtension.lowercased() == "gif" {
                                ChassisLabel(text: "GIF", size: 11)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .chassisPanel(cornerRadius: 14)
                                    .padding(10)
                            }
                        }
                        .padding(10)
                        .chassisPanel()
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .scaleEffect(developed ? 1 : 0.92)
                        .rotationEffect(.degrees(developed ? 0 : -1.5))
                        .animation(.spring(duration: 0.9, bounce: 0.22), value: developed)
                } else {
                    Text("Couldn't load photo").foregroundStyle(Chassis.textPrimary)
                }

                HStack(spacing: 24) {
                    PillButton(title: "Retake", prominent: false) {
                        model.retake()
                    }
                    PillButton(title: "Use Photo") {
                        model.accept()
                    }
                }
                .padding(.bottom, 40)
                .entrance(developed, delay: 0.35)
            }
        }
        .sensoryFeedback(.success, trigger: developed)
        .onAppear {
            withAnimation { developed = true }
            // Every other step in the flow (ReadyToShoot, Share) schedules
            // an auto-return — this one didn't, so a guest who glances at
            // their photo and walks off without tapping Retake/Use Photo
            // left the booth parked here indefinitely, blocking every
            // guest after them. The photo itself is already saved to disk
            // regardless (finishCapture wrote it before this screen ever
            // appeared), so resetting to attract loses nothing.
            model.scheduleAutoReturn(after: 20)
        }
    }
}

import SwiftUI

/// Retake-or-accept screen shown right after capture.
struct ReviewView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL

    var body: some View {
        ZStack {
            ChassisBackground()
            VStack(spacing: 32) {
                if let uiImage = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(10)
                        .chassisPanel()
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
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
            }
        }
    }
}

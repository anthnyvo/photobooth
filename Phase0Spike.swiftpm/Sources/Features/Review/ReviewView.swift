import SwiftUI

/// Retake-or-accept screen shown right after capture.
struct ReviewView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL

    var body: some View {
        ZStack {
            Chassis.base.ignoresSafeArea()
            VStack(spacing: 32) {
                if let uiImage = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(10)
                        .chassisPanel(cornerRadius: 24)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                } else {
                    Text("Couldn't load photo").foregroundStyle(Chassis.textPrimary)
                }

                HStack(spacing: 56) {
                    DialButton(label: "Retake", systemImage: "arrow.counterclockwise") {
                        model.retake()
                    }
                    DialButton(label: "Use Photo", systemImage: "checkmark", accent: theme.primary) {
                        model.accept()
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

import SwiftUI

/// Retake-or-accept screen shown right after capture.
struct ReviewView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                if let uiImage = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(24)
                } else {
                    Text("Couldn't load photo").foregroundStyle(.white)
                }

                HStack(spacing: 32) {
                    Button(action: model.retake) {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .font(.title2.bold())
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(.white.opacity(0.15))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Button(action: model.accept) {
                        Label("Use This Photo", systemImage: "checkmark")
                            .font(.title2.bold())
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(theme.primary)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

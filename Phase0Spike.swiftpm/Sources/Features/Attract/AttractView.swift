import SwiftUI

/// Idle/attract screen — loops live view as a backdrop with a "Tap to Start"
/// call to action. Branding-driven: logo and colors come from EventConfig,
/// nothing hardcoded here.
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(theme.background.opacity(0.35).ignoresSafeArea())
            }

            VStack(spacing: 24) {
                Spacer()
                if let logoName = model.config.logoAssetName {
                    let url = EventStorage.shared.assetURL(eventId: model.config.eventId, filename: logoName)
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 140)
                    }
                }
                Text(model.config.displayName)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                Spacer()
                Button(action: model.tapToStart) {
                    Text("Tap to Start")
                        .font(.title.bold())
                        .padding(.horizontal, 48)
                        .padding(.vertical, 20)
                        .background(theme.primary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 60)
            }

            if let error = model.lastError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tapToStart() }
    }
}

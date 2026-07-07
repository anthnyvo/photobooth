import SwiftUI

/// Share/print screen — every channel here is independently toggleable per
/// event via EventConfig.share/.print, never hardcoded on.
struct ShareView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL

    @StateObject private var printJob = PrintJob()

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                if let uiImage = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Text("Share your photo")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                HStack(spacing: 24) {
                    if model.config.share.airdrop {
                        ShareLink(item: photoURL) {
                            shareButton(label: "AirDrop", systemImage: "wifi")
                        }
                    }
                    if model.config.print.enabled {
                        Button {
                            printJob.print(photoURL: photoURL)
                        } label: {
                            shareButton(label: "Print", systemImage: "printer")
                        }
                    }
                }

                if let status = printJob.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Button("Done") {
                    model.returnToAttract()
                }
                .font(.title3.bold())
                .padding(.top, 12)
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
        .onAppear { model.scheduleAutoReturn() }
    }

    private func shareButton(label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.title2.bold())
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(theme.primary)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

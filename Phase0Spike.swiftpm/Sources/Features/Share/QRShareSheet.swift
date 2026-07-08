import SwiftUI

/// Scan-to-download sheet for the QR share option. Only reachable by a
/// guest's phone when this device and the camera are both on the same
/// venue Wi-Fi network — see LocalPhotoServer's doc comment for why.
struct QRShareSheet: View {
    let image: UIImage?
    let url: URL?
    let error: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Scan to download")
                .font(.title2.bold())

            if let error {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                if let url {
                    Text(url.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(width: 260, height: 260)
            }
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}

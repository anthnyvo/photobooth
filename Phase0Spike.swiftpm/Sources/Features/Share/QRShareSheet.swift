import SwiftUI

/// Scan-to-download sheet for the QR share option. Only reachable by a
/// guest's phone when this device and the camera are both on the same
/// venue Wi-Fi network — see LocalPhotoServer's doc comment for why.
struct QRShareSheet: View {
    let image: UIImage?
    let url: URL?
    let error: String?

    var body: some View {
        ZStack {
            Chassis.base.ignoresSafeArea()
            VStack(spacing: 24) {
                ChassisLabel(text: "Scan to Download", size: 14)

                if let error {
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Chassis.textSecondary)
                        .padding()
                } else if let image {
                    // QR stays on a white card — scanners need the light
                    // background; the dark chassis frames it instead.
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.white)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    if let url {
                        Text(url.absoluteString)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Chassis.textSecondary)
                    }
                } else {
                    ProgressView()
                        .tint(Chassis.textSecondary)
                        .frame(width: 240, height: 240)
                }
            }
            .padding(32)
        }
        .presentationDetents([.medium])
    }
}

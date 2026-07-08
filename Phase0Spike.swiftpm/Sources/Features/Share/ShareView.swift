import SwiftUI

/// Share/print screen — every channel here is independently toggleable per
/// event via EventConfig.share/.print, never hardcoded on.
struct ShareView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    let photoURL: URL

    @StateObject private var printJob = PrintJob()
    @State private var qrImage: UIImage?
    @State private var qrURL: URL?
    @State private var qrError: String?
    @State private var showingQR = false

    var body: some View {
        let uiImage = UIImage(contentsOfFile: photoURL.path)
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                if let uiImage {
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
                        // A bare file URL doesn't reliably present as an
                        // actual photo to third-party share targets (WhatsApp
                        // in particular silently drops it) — sharing the
                        // Image itself with an explicit JPEG-backed preview
                        // is what makes both AirDrop and other apps treat it
                        // as real image data instead of a generic file link.
                        if let uiImage {
                            ShareLink(item: Image(uiImage: uiImage), preview: SharePreview("Photo", image: Image(uiImage: uiImage))) {
                                shareButton(label: "AirDrop", systemImage: "wifi")
                            }
                        }
                    }
                    if model.config.share.qrGallery {
                        Button {
                            presentQR()
                        } label: {
                            shareButton(label: "QR Code", systemImage: "qrcode")
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
        .sheet(isPresented: $showingQR) {
            QRShareSheet(image: qrImage, url: qrURL, error: qrError)
        }
    }

    /// Starts the local server on first use (cheap, stays running for the
    /// rest of the session) and resolves this photo's guest-facing URL.
    /// Needs the camera joined to the venue's Wi-Fi (not its own private AP)
    /// so this device and the guest's phone share a network — see
    /// LocalPhotoServer's doc comment.
    private func presentQR() {
        qrImage = nil
        qrURL = nil
        qrError = nil
        showingQR = true
        Task {
            do {
                try await LocalPhotoServer.shared.start()
                guard let url = await LocalPhotoServer.shared.url(forPhoto: photoURL) else {
                    qrError = "Not connected to a Wi-Fi network — join the venue's Wi-Fi to enable QR sharing."
                    return
                }
                qrURL = url
                qrImage = QRCode.image(for: url.absoluteString)
            } catch {
                qrError = "Couldn't start local server: \(error)"
            }
        }
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

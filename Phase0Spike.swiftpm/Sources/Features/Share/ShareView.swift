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
            Chassis.base.ignoresSafeArea()
            VStack(spacing: 32) {
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(10)
                        .chassisPanel(cornerRadius: 22)
                }

                ChassisLabel(text: "Share Your Photo")

                HStack(spacing: 36) {
                    if model.config.share.airdrop {
                        // A bare file URL doesn't reliably present as an
                        // actual photo to third-party share targets (WhatsApp
                        // in particular silently drops it) — sharing the
                        // Image itself with an explicit JPEG-backed preview
                        // is what makes both AirDrop and other apps treat it
                        // as real image data instead of a generic file link.
                        if let uiImage {
                            ShareLink(item: Image(uiImage: uiImage), preview: SharePreview("Photo", image: Image(uiImage: uiImage))) {
                                dialFace(label: "AirDrop", systemImage: "wifi")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if model.config.share.qrGallery {
                        DialButton(label: "QR Code", systemImage: "qrcode") {
                            presentQR()
                        }
                    }
                    if model.config.print.enabled {
                        DialButton(label: "Print", systemImage: "printer") {
                            printJob.print(photoURL: photoURL)
                        }
                    }
                }

                if let status = printJob.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                }

                Button {
                    model.returnToAttract()
                } label: {
                    ChassisLabel(text: "Done", size: 14)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 36)
                        .chassisPanel(cornerRadius: 26)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
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
        // Explicit @MainActor: BoothViewModel and this view's state updates
        // need to land on the main actor to actually trigger a SwiftUI
        // redraw. Plain `Task { }` runs detached from any actor, so the
        // qrImage/qrURL/qrError writes below could complete off-main and
        // silently never repaint the sheet (spinner stuck forever).
        Task { @MainActor in
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

    /// DialButton's face without the Button wrapper — ShareLink supplies its
    /// own tap handling, so it needs a plain label view rather than a nested
    /// button. Kept visually identical to DialButton (Theme.swift).
    private func dialFace(label: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Chassis.controlHighlight, Chassis.control],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Circle()
                    .strokeBorder(Chassis.hairline, lineWidth: 1)
                Circle()
                    .strokeBorder(Chassis.hairline, lineWidth: 1)
                    .padding(7)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Chassis.textPrimary)
            }
            .frame(width: 88, height: 88)
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)

            ChassisLabel(text: label, size: 11)
        }
    }
}

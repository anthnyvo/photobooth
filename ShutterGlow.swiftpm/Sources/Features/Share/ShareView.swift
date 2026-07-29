import SwiftUI
import MessageUI
import BoothStorage

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
    @State private var showingMail = false
    @State private var showingDataCapture = false
    /// Scoped to this one guest's turn — this view is freshly created per
    /// BoothStep.sharing(url), so a plain @State counter is already exactly
    /// "prints used this session," no BoothViewModel bookkeeping needed.
    @State private var printsThisSession = 0
    @State private var entered = false

    var body: some View {
        let uiImage = UIImage(contentsOfFile: photoURL.path)
        ZStack {
            ChassisBackground()
            VStack(spacing: 32) {
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(10)
                        .chassisPanel()
                        .entrance(entered)
                }

                ChassisLabel(text: "Share Your Photo")
                    .entrance(entered, delay: 0.08)

                HStack(spacing: 36) {
                    if model.config.share.airdrop {
                        // A bare file URL doesn't reliably present as an
                        // actual photo to third-party share targets (WhatsApp
                        // in particular silently drops it) — sharing the
                        // Image itself with an explicit JPEG-backed preview
                        // is what makes both AirDrop and other apps treat it
                        // as real image data instead of a generic file link.
                        // GIFs are the exception: re-wrapping as Image would
                        // flatten the animation to one frame, so those share
                        // as the file URL (extension makes targets treat it
                        // as an animated GIF).
                        if isGIF {
                            ShareLink(item: photoURL, preview: SharePreview("GIF", image: uiImage.map(Image.init) ?? Image(systemName: "film"))) {
                                dialFace(label: "AirDrop", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(shareSheetGraceGesture)
                        } else if let uiImage {
                            ShareLink(item: Image(uiImage: uiImage), preview: SharePreview("Photo", image: Image(uiImage: uiImage))) {
                                dialFace(label: "AirDrop", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(shareSheetGraceGesture)
                        }
                    }
                    if model.config.share.qrGallery && model.qrSharingAvailable {
                        DialButton(label: "QR Code", systemImage: "qrcode") {
                            presentQR()
                        }
                    }
                    if model.config.share.email && MFMailComposeViewController.canSendMail() {
                        DialButton(label: "Email", systemImage: "envelope") {
                            showingMail = true
                        }
                    }
                    // Behind-the-scenes timelapse of the strip session —
                    // shares as a file URL for the same animation-preserving
                    // reason as GIF captures.
                    if let timelapseURL = model.timelapseURL {
                        ShareLink(item: timelapseURL, preview: SharePreview("Timelapse", image: Image(systemName: "timelapse"))) {
                            dialFace(label: "Timelapse", systemImage: "timelapse")
                        }
                        .buttonStyle(PressableStyle())
                        .simultaneousGesture(shareSheetGraceGesture)
                    }
                    // Print is stills-only — an animated GIF can't print.
                    if model.config.print.enabled && !isGIF {
                        DialButton(label: "Print", systemImage: "printer") {
                            // Count on the tap being allowed — but the credit
                            // is only actually consumed on a confirmed
                            // "Sent to printer" (see onChange below). A
                            // cancelled/failed dialog must not burn a guest's
                            // only print on a limit-1 event.
                            printJob.print(photoURL: photoURL)
                        }
                        .disabled(printLimitReached)
                        .opacity(printLimitReached ? 0.4 : 1)
                    }
                }
                .entrance(entered, delay: 0.14)

                if printLimitReached {
                    Text("Print limit reached for this guest")
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                } else if let status = printJob.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                }

                PillButton(title: "Done") {
                    model.returnToAttract()
                }
                .padding(.top, 8)
                .entrance(entered, delay: 0.22)
            }
            .padding()
        }
        .onAppear {
            entered = true
            // Gate the share screen behind the lead form when the event
            // collects data and this guest hasn't been prompted yet. The
            // auto-return timer is paused while the form is up (below).
            if model.config.dataCapture.enabled && !model.leadCollectedThisSession {
                showingDataCapture = true
            } else {
                model.scheduleAutoReturn()
            }
        }
        .sheet(isPresented: $showingDataCapture, onDismiss: {
            model.scheduleAutoReturn()
        }) {
            DataCaptureView(options: model.config.dataCapture) { lead in
                model.submitLead(lead)
                showingDataCapture = false
            }
            .interactiveDismissDisabled(true)
        }
        .onChange(of: showingDataCapture) { _, open in
            if open { model.cancelAutoReturn() }
        }
        .sheet(isPresented: $showingQR) {
            QRShareSheet(image: qrImage, url: qrURL, error: qrError)
        }
        .sheet(isPresented: $showingMail) {
            MailComposeView(photoURL: photoURL)
        }
        // Pause the idle auto-return while any share surface is open, and
        // re-arm it once the guest closes it — otherwise the 20s timer fires
        // mid-share and discards a half-composed email or an open QR sheet.
        .onChange(of: showingQR) { _, open in
            if open { model.cancelAutoReturn() } else { model.scheduleAutoReturn() }
        }
        .onChange(of: showingMail) { _, open in
            if open { model.cancelAutoReturn() } else { model.scheduleAutoReturn() }
        }
        .onChange(of: printJob.statusMessage) { _, message in
            switch message {
            case "Sending to printer…":
                // Print dialog is up — don't let auto-return kill it.
                model.cancelAutoReturn()
            case "Sent to printer":
                // Consume the per-guest credit only on a confirmed send, so
                // the disable-at-limit gate reflects real prints, not taps.
                printsThisSession += 1
                EventStorage.shared.recordPrint(eventId: model.config.eventId)
                model.scheduleAutoReturn()
            default:
                // Terminal (cancelled/failed/cleared) — resume the timer.
                model.scheduleAutoReturn()
            }
        }
    }

    /// ShareLink presents the system share sheet with no dismissal callback,
    /// so unlike the QR/mail/print sheets it can't pause-and-resume the idle
    /// timer around its exact lifetime. Every other share surface pauses the
    /// 20s auto-return; without this, it fired mid-AirDrop and tore the
    /// screen (and the share sheet) down. A tap instead re-arms with a long
    /// grace window — plenty for an AirDrop, but the booth still recovers if
    /// the guest walks off with the sheet open.
    private var shareSheetGraceGesture: some Gesture {
        TapGesture().onEnded {
            model.scheduleAutoReturn(after: 120)
        }
    }

    private var isGIF: Bool {
        photoURL.pathExtension.lowercased() == "gif"
    }

    private var printLimitReached: Bool {
        guard let limit = model.config.print.limitPerGuest else { return false }
        return printsThisSession >= limit
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
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Chassis.hairline, lineWidth: 1)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Chassis.textPrimary)
            }
            .frame(width: 84, height: 84)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

            ChassisLabel(text: label, size: 11)
        }
    }
}
